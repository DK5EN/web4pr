#!/usr/bin/env bash
# Web4PR Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/DK5EN/web4pr/main/install.sh | sudo bash
# Flags: --yes   non-interactive (auto-confirm upgrades, skip if already current)
set -euo pipefail

# ─── colors & logging ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*" >&2; }
die()    { error "$*"; exit 1; }
banner() { echo -e "\n${CYAN}${BOLD}$*${NC}\n"; }
ask()    { echo -en "${BOLD}$*${NC}"; }  # prompt without newline

# ─── constants ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/web4pr"
SERVICE_USER="web4pr"
SERVICE_FILE="/lib/systemd/system/web4pr.service"
GITHUB_REPO="DK5EN/web4pr"
VERSION_FILE="${INSTALL_DIR}/.version"

# ─── parse flags ──────────────────────────────────────────────────────────────
AUTO_YES=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    *)        POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ─── check: must run as root ───────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || die "This installer must be run as root.  Try: curl ... | sudo bash"
}

# ─── check: Debian Bookworm or Trixie ─────────────────────────────────────────
OS_CODENAME=""
check_os() {
  [[ -f /etc/os-release ]] || die "Cannot determine OS — /etc/os-release not found"
  # shellcheck source=/dev/null
  . /etc/os-release
  local id="${ID:-}"
  local like="${ID_LIKE:-}"
  [[ "$id" == "debian" || "$like" == *"debian"* ]] || \
    die "Requires Debian (Bookworm/Trixie). Detected: ${PRETTY_NAME:-unknown}"

  OS_CODENAME="${VERSION_CODENAME:-}"
  case "$OS_CODENAME" in
    bookworm|trixie) info "OS: ${PRETTY_NAME}" ;;
    *) warn "Untested OS version: ${PRETTY_NAME} — continuing anyway" ;;
  esac
}

# ─── preflight checks ─────────────────────────────────────────────────────────
preflight_checks() {
  banner "Pre-Flight Checks"
  local failures=0

  # 1) Python >= 3.11
  local found_py=""
  for pyver in python3.12 python3.11; do
    if $pyver --version &>/dev/null 2>&1; then
      found_py="$pyver"
      break
    fi
  done
  if [[ -n "$found_py" ]]; then
    info "Python:  $($found_py --version) ✓"
  else
    local sysver
    sysver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "not found")
    warn "Python:  ${sysver} — Python >= 3.11 will be installed"
  fi

  # 2) RAM (minimum 256 MB total)
  local total_mb
  total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  local avail_mb
  avail_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
  if [[ "$total_mb" -lt 256 ]]; then
    error "RAM:     ${total_mb} MB total — minimum 256 MB required"
    ((failures++))
  elif [[ "$total_mb" -lt 512 ]]; then
    warn "RAM:     ${total_mb} MB total (${avail_mb} MB available) — tight but workable"
  else
    info "RAM:     ${total_mb} MB total (${avail_mb} MB available) ✓"
  fi

  # 3) uv
  if command -v uv &>/dev/null; then
    info "uv:      $(uv --version) ✓"
  else
    warn "uv:      not found — will be installed"
  fi

  # 4) Ports 8080 and 10093 free (ignore if held by web4pr itself)
  local port_ok=true
  for port in 8080 10093; do
    local port_line
    port_line=$(ss -tulpn 2>/dev/null | grep ":${port} " || true)
    if [[ -n "$port_line" ]]; then
      if echo "$port_line" | grep -q "web4pr\|uvicorn"; then
        info "Port:    ${port} in use by Web4PR (will be restarted) ✓"
      else
        error "Port:    ${port} is already in use by another process"
        ((failures++))
        port_ok=false
      fi
    fi
  done
  if $port_ok; then
    info "Ports:   8080 and 10093 available ✓"
  fi

  # 5) HAMNET connectivity (44.224.64.4 = db0fhn)
  if ping -c1 -W3 44.224.64.4 &>/dev/null; then
    info "HAMNET:  reachable ✓"
  else
    warn "HAMNET:  not reachable — VPN may need to be started after install"
  fi

  echo
  if [[ "$failures" -gt 0 ]]; then
    die "Pre-flight checks failed (${failures} critical). Fix the issues above before installing."
  fi
  info "Pre-flight checks passed"
}

# ─── install base deps (git required for aioax25 git dependency) ───────────────
install_deps() {
  info "Installing base packages..."
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git curl ca-certificates openssl
}

# ─── install Python >= 3.11 ───────────────────────────────────────────────────
PYTHON_BIN=""

install_python() {
  # Prefer 3.12+, fall back to 3.11
  for pyver in python3.12 python3.11; do
    if $pyver --version &>/dev/null 2>&1; then
      PYTHON_BIN="$pyver"
      info "Python:  $($pyver --version) ✓"
      return
    fi
  done

  info "Installing Python..."
  if [[ "$OS_CODENAME" == "bookworm" ]]; then
    # Try 3.12 from backports first, fall back to 3.11
    local list="/etc/apt/sources.list.d/bookworm-backports.list"
    if ! grep -q "bookworm-backports" "$list" 2>/dev/null; then
      echo "deb http://deb.debian.org/debian bookworm-backports main" > "$list"
      apt-get update -q
    fi
    if apt-cache show python3.12 &>/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -t bookworm-backports \
        python3.12 python3.12-venv
      PYTHON_BIN="python3.12"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3.11 python3.11-venv
      PYTHON_BIN="python3.11"
    fi
  else
    # Trixie+ should have 3.12+
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-venv
    PYTHON_BIN="python3"
  fi

  $PYTHON_BIN --version || die "Python installation failed"
}

# ─── install uv ───────────────────────────────────────────────────────────────
install_uv() {
  if command -v uv &>/dev/null; then
    info "uv already available: $(uv --version)"
    return
  fi

  info "Installing uv..."
  local arch
  arch=$(uname -m)
  local triple
  case "$arch" in
    x86_64)  triple="x86_64-unknown-linux-musl" ;;
    aarch64) triple="aarch64-unknown-linux-musl" ;;
    armv7l)  triple="armv7-unknown-linux-musleabihf" ;;
    *) die "Unsupported CPU architecture: $arch" ;;
  esac

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL \
    "https://github.com/astral-sh/uv/releases/latest/download/uv-${triple}.tar.gz" \
    | tar xz -C "$tmp" --strip-components=1
  install -m 755 "$tmp/uv" /usr/local/bin/uv
  info "uv installed: $(uv --version)"
}

# ─── fetch latest release version from GitHub ─────────────────────────────────
get_latest_version() {
  curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4
}

# ─── download release tarball ─────────────────────────────────────────────────
TMP_RELEASE=""
VERSION=""

download_release() {
  local arg="${1:-}"

  # Local tarball: install.sh /path/to/web4pr-v0.2.0.tar.gz
  if [[ -n "$arg" && -f "$arg" ]]; then
    info "Using local tarball: ${arg}"
    VERSION=$(basename "$arg" | sed 's/web4pr-//;s/\.tar\.gz//')
    TMP_RELEASE=$(mktemp -d)
    cp "$arg" "$TMP_RELEASE/web4pr.tar.gz"
    return
  fi

  # Version tag: install.sh v0.2.0
  if [[ -n "$arg" ]]; then
    VERSION="$arg"
  else
    info "Fetching latest release version..."
    VERSION=$(get_latest_version)
    [[ -n "$VERSION" ]] || die "Could not determine latest release — check GitHub connectivity"
  fi

  info "Downloading Web4PR ${VERSION}..."
  local url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/web4pr-${VERSION}.tar.gz"

  TMP_RELEASE=$(mktemp -d)
  curl -fsSL --progress-bar "$url" -o "$TMP_RELEASE/web4pr.tar.gz" \
    || die "Download failed: $url"
}

# ─── detect existing installation ─────────────────────────────────────────────
IS_UPGRADE=false
INSTALLED_VERSION=""

check_existing() {
  if [[ -f "$INSTALL_DIR/data/config.json" ]]; then
    IS_UPGRADE=true

    # Read installed version if available
    if [[ -f "$VERSION_FILE" ]]; then
      INSTALLED_VERSION=$(cat "$VERSION_FILE")
    fi

    # Already at target version — nothing to do
    if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" == "$VERSION" ]]; then
      info "Web4PR ${VERSION} is already installed and up to date"
      exit 0
    fi

    if [[ -n "$INSTALLED_VERSION" ]]; then
      warn "Existing installation: ${INSTALLED_VERSION} → upgrading to ${VERSION}"
    else
      warn "Existing installation detected (unknown version) → upgrading to ${VERSION}"
    fi

    if ! $AUTO_YES; then
      ask "  Upgrade to ${VERSION}? [y/N] "
      local answer
      read -r answer </dev/tty
      [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted"
    fi
  fi
}

# ─── install application ───────────────────────────────────────────────────────
install_app() {
  info "Installing to ${INSTALL_DIR}..."

  # Create directories
  mkdir -p "$INSTALL_DIR/data/logs"

  # Stop service if upgrading
  if $IS_UPGRADE && systemctl is-active --quiet web4pr 2>/dev/null; then
    info "Stopping existing service..."
    systemctl stop web4pr
  fi

  # Extract tarball (strip top-level versioned dir: web4pr-vX.Y.Z/)
  # --warning=no-unknown-keyword suppresses macOS xattr noise (com.apple.provenance)
  tar xzf "$TMP_RELEASE/web4pr.tar.gz" --strip-components=1 -C "$INSTALL_DIR" \
    --warning=no-unknown-keyword 2>/dev/null || \
  tar xzf "$TMP_RELEASE/web4pr.tar.gz" --strip-components=1 -C "$INSTALL_DIR"

  rm -rf "$TMP_RELEASE"

  # Write version marker (idempotency: enables skip-if-current on re-run)
  echo "$VERSION" > "$VERSION_FILE"

  # Create service user
  if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin \
      --comment "Web4PR service" "$SERVICE_USER"
    info "Created service user: ${SERVICE_USER}"
  fi

  # Set permissions: app files root-owned, data dir web4pr-owned
  chown -R root:root "$INSTALL_DIR"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/data"
  chmod 750 "$INSTALL_DIR/data"

  # Install Python dependencies into .venv
  info "Installing Python dependencies..."
  cd "$INSTALL_DIR"
  uv sync --frozen --no-dev --python "$PYTHON_BIN"
  info "Dependencies installed"
}

# ─── merge endpoints on upgrade ──────────────────────────────────────────────
merge_endpoints() {
  local config_file="${INSTALL_DIR}/data/config.json"
  local default_file="${INSTALL_DIR}/config.default.json"

  [[ -f "$config_file" && -f "$default_file" ]] || return 0

  info "Merging endpoint updates..."
  "$INSTALL_DIR/.venv/bin/python" - "$config_file" "$default_file" <<'PYEOF'
import json, sys

config_file, default_file = sys.argv[1], sys.argv[2]

with open(config_file) as f:
    cfg = json.load(f)
with open(default_file) as f:
    defaults = json.load(f)

existing = {ep["remote_callsign"] for ep in cfg.get("endpoints", [])}
added = []

for ep in defaults.get("endpoints", []):
    if ep["remote_callsign"] not in existing:
        cfg.setdefault("endpoints", []).append(ep)
        added.append(ep["remote_callsign"])

# Remove endpoints no longer in defaults (unless user-added with custom IDs)
default_callsigns = {ep["remote_callsign"] for ep in defaults.get("endpoints", [])}
default_ids = {ep["id"] for ep in defaults.get("endpoints", [])}
before = len(cfg.get("endpoints", []))
cfg["endpoints"] = [
    ep for ep in cfg.get("endpoints", [])
    if ep["remote_callsign"] in default_callsigns or ep["id"] not in default_ids
]
removed = before - len(cfg["endpoints"])

if added or removed:
    with open(config_file, "w") as f:
        json.dump(cfg, f, indent=2)
    if added:
        print(f"  Added endpoints: {', '.join(added)}")
    if removed:
        print(f"  Removed {removed} obsolete endpoint(s)")
else:
    print("  Endpoints already up to date")
PYEOF
}

# ─── interactive first-run setup ──────────────────────────────────────────────
CALLSIGN="" SSID=0 USERNAME="" PORT=8080
HASHED_PASSWORD="" JWT_SECRET=""

interactive_setup() {
  if $IS_UPGRADE; then
    merge_endpoints
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/data/config.json"
    info "Upgrade — existing configuration preserved"
    return
  fi

  if $AUTO_YES; then
    die "Fresh install requires interactive setup (callsign, password). Run without --yes."
  fi

  banner "Web4PR First-Run Setup"
  echo "  This creates your initial configuration."
  echo "  You can change all settings later in the web UI."
  echo

  # Callsign
  ask "  Your callsign (e.g. DK5EN): "
  read -r CALLSIGN </dev/tty
  CALLSIGN=$(echo "$CALLSIGN" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  [[ -n "$CALLSIGN" ]] || die "Callsign is required"

  # SSID
  ask "  SSID [0]: "
  local ssid_input
  read -r ssid_input </dev/tty
  SSID="${ssid_input:-0}"
  [[ "$SSID" =~ ^[0-9]+$ && "$SSID" -le 15 ]] || die "SSID must be 0-15"

  # Admin username
  local default_user
  default_user=$(echo "$CALLSIGN" | tr '[:upper:]' '[:lower:]')
  ask "  Admin username [${default_user}]: "
  read -r USERNAME </dev/tty
  USERNAME="${USERNAME:-$default_user}"

  # Password
  local pass1 pass2
  while true; do
    ask "  Admin password: "
    read -rs pass1 </dev/tty; echo
    ask "  Confirm password: "
    read -rs pass2 </dev/tty; echo
    [[ "$pass1" == "$pass2" ]] && break
    warn "Passwords do not match, try again"
  done

  # Hash password using bcrypt (available after uv sync)
  info "Hashing password..."
  HASHED_PASSWORD=$(
    PASS="$pass1" "$INSTALL_DIR/.venv/bin/python" -c \
      "import bcrypt, os; print(bcrypt.hashpw(os.environ['PASS'].encode(), bcrypt.gensalt()).decode())"
  )

  # Generate JWT secret
  JWT_SECRET=$(openssl rand -base64 32 | tr -d '\n=/')

  # Port
  ask "  Web interface port [8080]: "
  local port_input
  read -r port_input </dev/tty
  PORT="${port_input:-8080}"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port number"
}

# ─── write config.json (first install only) ───────────────────────────────────
write_config() {
  if $IS_UPGRADE; then
    return
  fi

  info "Writing configuration..."

  CALLSIGN="$CALLSIGN" SSID="$SSID" USERNAME="$USERNAME" \
  HASHED_PASSWORD="$HASHED_PASSWORD" JWT_SECRET="$JWT_SECRET" \
  PORT="$PORT" INSTALL_DIR="$INSTALL_DIR" \
  "$INSTALL_DIR/.venv/bin/python" - <<'PYEOF'
import json, os

install_dir = os.environ["INSTALL_DIR"]

# Read endpoints from config.default.json (single source of truth)
default_file = os.path.join(install_dir, "config.default.json")
with open(default_file) as f:
    defaults = json.load(f)

config = {
    "version": 1,
    "identity": {
        "callsign": os.environ["CALLSIGN"],
        "ssid": int(os.environ["SSID"])
    },
    "endpoints": defaults["endpoints"],
    "incoming": {
        "enabled": False,
        "listen_port": 10093,
        "auto_answer": False,
        "auto_answer_callsigns": []
    },
    "ax25": defaults.get("ax25", {
        "t1_timeout_ms": 3000,
        "t2_response_delay_ms": 300,
        "t3_inactivity_timeout_ms": 180000,
        "n1_max_frame_length": 256,
        "n2_max_retries": 10,
        "modulo": 8
    }),
    "application": {
        "websocket_port": int(os.environ["PORT"]),
        "log_level": "INFO",
        "monitor_mode": False,
        "log_directory": os.path.join(install_dir, "data", "logs")
    },
    "users": [{
        "username": os.environ["USERNAME"],
        "hashed_password": os.environ["HASHED_PASSWORD"],
        "callsign": os.environ["CALLSIGN"],
        "is_admin": True
    }],
    "jwt_secret": os.environ["JWT_SECRET"]
}

config_file = os.path.join(install_dir, "data", "config.json")
with open(config_file, "w") as f:
    json.dump(config, f, indent=2)
PYEOF

  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/data/config.json"
  chmod 640 "$INSTALL_DIR/data/config.json"
}

# ─── systemd service ──────────────────────────────────────────────────────────
setup_systemd() {
  info "Installing systemd service..."

  # Read port from config if upgrading
  if $IS_UPGRADE; then
    PORT=$(
      "$INSTALL_DIR/.venv/bin/python" -c \
        "import json; cfg=json.load(open('${INSTALL_DIR}/data/config.json')); \
         print(cfg.get('application',{}).get('websocket_port', 8080))"
    )
  fi

  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Web4PR — Web-based Packet Radio Client
Documentation=https://github.com/DK5EN/web4pr
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn web4pr.main:app --host 0.0.0.0 --port ${PORT}
Restart=on-failure
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}/data /tmp

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable web4pr
  systemctl restart web4pr
  info "Service started"
}

# ─── print success summary ────────────────────────────────────────────────────
print_summary() {
  local ip
  ip=$(hostname -I | awk '{print $1}')

  echo
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║   Web4PR ${VERSION} installed!              ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo
  echo -e "  Open in your browser:  ${CYAN}http://${ip}:${PORT}${NC}"
  echo
  echo -e "  Service management:"
  echo -e "    ${BOLD}systemctl status web4pr${NC}"
  echo -e "    ${BOLD}journalctl -u web4pr -f${NC}"
  echo
  if ! $IS_UPGRADE; then
    echo -e "  Login with username: ${BOLD}${USERNAME}${NC}"
  fi
  echo
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  banner "Web4PR Installer"

  check_root
  check_os
  preflight_checks
  install_deps
  install_python
  install_uv
  download_release "${1:-}"   # optional: pass specific version or local tarball
  check_existing              # exits early if already at target version
  install_app
  interactive_setup
  write_config
  setup_systemd
  print_summary
}

main "$@"
