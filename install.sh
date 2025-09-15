#!/usr/bin/env bash

# Nivora API installer
# Usage:
#   ./install.sh [--method docker|pm2|binary] [--no-build] [--no-up]
# Defaults to method=pm2 if Go and PM2 are present, else docker if Docker is present, else binary.

set -euo pipefail

PROJECT_NAME="nivora-api"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_BIN="$ROOT_DIR/build/nivora-api"
ECOSYSTEM="$ROOT_DIR/ecosystem.config.js"
DOCKER_COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"

# ---------- helpers ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; NC="\033[0m"
log() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- package install helpers (apt-based) ----------
APT_UPDATED="false"
apt_update_once() {
  if have apt-get && [[ "$APT_UPDATED" != "true" ]]; then
    log "Updating apt package index..."
    sudo apt-get update -y || true
    APT_UPDATED="true"
  fi
}

apt_install() {
  # usage: apt_install pkg1 pkg2 ...
  if have apt-get; then
    apt_update_once
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    return 1
  fi
}

ensure_curl_installed() {
  if have curl; then
    return 0
  fi
  warn "curl not found. Attempting to install..."
  if apt_install curl ca-certificates; then
    ok "curl installed."
  else
    err "Failed to install curl automatically. Please install curl manually."
    return 1
  fi
}

ensure_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log ".env already exists. Skipping copy."
  elif [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    ok "Generated .env from .env.example"
  else
    warn "No .env or .env.example found. You must create $ENV_FILE manually."
  fi
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif have docker-compose; then
    echo "docker-compose"
  else
    echo "" 
  fi
}

go_version_ge() {
  # require >= 1.21
  local need_major=1 need_minor=21
  if ! have go; then return 1; fi
  local ver
  ver=$(go version | awk '{print $3}' | sed 's/go//')
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  if (( major > need_major || (major == need_major && minor >= need_minor) )); then
    return 0
  fi
  return 1
}

# Install Go (official tarball) if missing or version < 1.21
install_go() {
  local GO_VERSION="1.22.5"
  ensure_curl_installed || return 1
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) err "Unsupported architecture $(uname -m) for automated Go install."; return 1 ;;
  esac
  log "Installing Go ${GO_VERSION} to /usr/local ..."
  local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  curl -fsSLo "/tmp/${tarball}" "https://go.dev/dl/${tarball}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"
  # Ensure PATH update for interactive shells
  if ! grep -q "/usr/local/go/bin" "$HOME/.profile" 2>/dev/null; then
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> "$HOME/.profile"
  fi
  if ! grep -q "/usr/local/go/bin" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> "$HOME/.bashrc"
  fi
  export PATH="/usr/local/go/bin:$PATH"
  ok "Go installed. Version: $(go version || true)"
}

ensure_go_installed() {
  if go_version_ge; then
    ok "Go present: $(go version)"
    return 0
  fi
  warn "Go >= 1.21 not found. Installing..."
  install_go || {
    err "Failed to install Go automatically. Please install Go >= 1.21 manually: https://go.dev/dl/"; return 1;
  }
  if ! go_version_ge; then
    err "Go installation seems incomplete or version too low."
    return 1
  fi
}

# ---------- PostgreSQL helpers ----------
service_enable_start() {
  local svc="$1"
  if have systemctl; then
    sudo systemctl enable --now "$svc" 2>/dev/null || sudo systemctl start "$svc" 2>/dev/null || true
  fi
}

env_get() {
  local key="$1"; local def_val="$2"
  local val=""
  if [[ -f "$ENV_FILE" ]]; then
    val=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r')
    # strip surrounding quotes if any
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  fi
  [[ -z "$val" ]] && val="$def_val"
  echo "$val"
}

sql_escape() {
  # escape single quotes for SQL literals
  echo "$1" | sed "s/'/''/g"
}

configure_postgres_db() {
  local db_user db_pass db_name
  db_user=$(env_get MASTER_DB_USER postgres)
  db_pass=$(env_get MASTER_DB_PASSWORD postgres)
  db_name=$(env_get MASTER_DB_NAME nivora)

  local esc_user esc_pass esc_db
  esc_user=$(sql_escape "$db_user")
  esc_pass=$(sql_escape "$db_pass")
  esc_db=$(sql_escape "$db_name")

  log "Configuring PostgreSQL role '$db_user' and database '$db_name' ..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -qtAX -c "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${esc_user}') THEN CREATE ROLE \"${esc_user}\" LOGIN PASSWORD '${esc_pass}'; ELSE ALTER ROLE \"${esc_user}\" WITH LOGIN PASSWORD '${esc_pass}'; END IF; END $$;" >/dev/null
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -qtAX -c "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_database WHERE datname='${esc_db}') THEN CREATE DATABASE \"${esc_db}\" OWNER \"${esc_user}\"; END IF; END $$;" >/dev/null
  ok "PostgreSQL configured."
}

install_postgres() {
  if have apt-get; then
    log "Installing PostgreSQL via apt..."
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
    service_enable_start postgresql
  else
    err "Unsupported distro for automatic PostgreSQL install. Install it manually."
    return 1
  fi
  ok "PostgreSQL installed."
}

ensure_postgres_installed() {
  if have psql; then
    ok "psql present: $(psql --version | awk '{print $3}')"
  else
    warn "PostgreSQL client/server not found. Installing..."
    install_postgres || { err "Failed to install PostgreSQL automatically."; return 1; }
  fi
  # Ensure service is running
  service_enable_start postgresql
  # Configure DB/user based on .env
  configure_postgres_db || warn "Database configuration step encountered an issue. Check PostgreSQL setup."
}

# ---------- Docker helpers ----------
install_docker_and_compose() {
  if ! have apt-get; then
    err "Automatic Docker install only supported on apt-based distros in this script."
    return 1
  fi
  log "Installing Docker Engine (apt)..."
  apt_install ca-certificates curl gnupg lsb-release || true
  ensure_curl_installed || true
  # Use distro package as a simple default
  if apt_install docker.io; then
    ok "Docker Engine installed via docker.io"
  else
    err "Failed to install Docker Engine via apt."
    return 1
  fi
  # Compose plugin (preferred) and legacy docker-compose (fallback)
  if apt_install docker-compose-plugin; then
    ok "Docker Compose plugin installed."
  else
    warn "Compose plugin install failed, trying legacy docker-compose..."
    apt_install docker-compose || warn "Could not install legacy docker-compose."
  fi
  service_enable_start docker || true
  # Add current user to docker group to run without sudo (will require re-login)
  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker "$USER" || true
  fi
}

ensure_compose_available() {
  local cmd
  cmd="$(detect_compose_cmd)"
  if [[ -n "$cmd" ]]; then
    echo "$cmd"
    return 0
  fi
  warn "Docker Compose not found. Attempting to install..."
  install_docker_and_compose || return 1
  cmd="$(detect_compose_cmd)"
  if [[ -z "$cmd" ]]; then
    err "Docker Compose still not available after install."
    return 1
  fi
  echo "$cmd"
}

# ---------- PM2 helpers ----------
ensure_pm2_installed() {
  if have pm2; then
    return 0
  fi
  warn "PM2 not found. Attempting to install..."
  if have npm; then
    if sudo npm i -g pm2 >/dev/null 2>&1; then
      ok "PM2 installed via npm."
      return 0
    fi
    warn "Failed to install PM2 via existing npm."
  fi
  # Try to install Node.js (apt) then PM2
  if have apt-get; then
    apt_install nodejs npm || {
      # fallback to Nodesource setup for newer Node if repo provides old versions
      ensure_curl_installed || true
      warn "Installing Node.js via NodeSource (requires network)..."
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || true
      apt_install nodejs || true
    }
    if have npm; then
      sudo npm i -g pm2 && ok "PM2 installed." && return 0
    fi
  fi
  err "Could not install PM2 automatically. Please install Node.js and run: npm i -g pm2"
  return 1
}

build_binary() {
  log "Building Go binary..."
  mkdir -p "$ROOT_DIR/build"
  (cd "$ROOT_DIR" && go build -o "$BUILD_BIN" main.go)
  ok "Built $BUILD_BIN"
}

start_pm2() {
  if [[ ! -f "$ECOSYSTEM" ]]; then
    err "ecosystem.config.js not found at $ECOSYSTEM"
    exit 1
  fi
  if [[ ! -x "$BUILD_BIN" ]]; then
    err "Binary not found at $BUILD_BIN. Build failed or skipped."
    exit 1
  fi
  log "Starting with PM2..."
  pm2 start "$ECOSYSTEM" --update-env
  pm2 save || true
  ok "PM2 started. Use: pm2 status | pm2 logs"
}

pm2_startup_if_requested=true
no_build=false
no_up=false
method=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)
      method="${2:-}"; shift 2 ;;
    --no-build)
      no_build=true; shift ;;
    --no-up)
      no_up=true; shift ;;
    -h|--help)
      cat <<EOF
Nivora API installer

Options:
  --method <docker|pm2|binary>  Choose installation method.
  --no-build                     Skip building the Go binary.
  --no-up                        Skip starting services/containers.
  -h, --help                     Show this help.

Examples:
  ./install.sh --method docker
  ./install.sh --method pm2
  ./install.sh --method binary
EOF
      exit 0 ;;
    *)
      warn "Unknown option: $1"; shift ;;
  esac
done

# auto-detect method if not provided
if [[ -z "$method" ]]; then
  if go_version_ge && have pm2; then
    method="pm2"
  elif [[ -n "$(detect_compose_cmd)" ]]; then
    method="docker"
  elif go_version_ge; then
    method="binary"
  else
    method="docker"
  fi
fi

log "Installation method: $method"

# -------- common prep --------
ensure_env
mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/build"

case "$method" in
  docker)
    if ! have docker; then
      warn "Docker not found. Attempting to install..."
      install_docker_and_compose || { err "Docker install failed. See https://docs.docker.com/engine/install/"; exit 1; }
    fi
    compose_cmd="$(ensure_compose_available)" || { err "Docker Compose not available."; exit 1; }
    if [[ "$no_up" == true ]]; then
      log "Skipping compose up due to --no-up"
      exit 0
    fi
    log "Starting containers with $compose_cmd..."
    if [[ "$compose_cmd" == "docker compose" ]]; then
      (cd "$ROOT_DIR" && docker compose -f "$DOCKER_COMPOSE_FILE" up -d --build)
    else
      (cd "$ROOT_DIR" && docker-compose -f "$DOCKER_COMPOSE_FILE" up -d --build)
    fi
    ok "Containers are up. App should be on port 59152."
    ;;

  pm2)
  ensure_go_installed || { err "Go is required for PM2 method."; exit 1; }
  ensure_pm2_installed || { err "PM2 is required for PM2 method."; exit 1; }
  ensure_postgres_installed || warn "PostgreSQL setup skipped or failed; ensure DB is reachable per .env."
    if [[ "$no_build" != true ]]; then
      build_binary
    else
      warn "Skipping build due to --no-build"
    fi
    if [[ "$no_up" != true ]]; then
      start_pm2
      if [[ "$pm2_startup_if_requested" == true ]]; then
        log "Configuring PM2 startup (requires sudo)..."
        # Respect user's HOME and username
        sudo env PATH=$PATH:$(dirname "$(command -v node || echo /usr/bin)") pm2 startup systemd -u "$USER" --hp "$HOME" || true
        pm2 save || true
        ok "PM2 startup configured."
      fi
    else
      warn "Skipping PM2 start due to --no-up"
    fi
    ;;

  binary)
  ensure_go_installed || { err "Go is required for binary method."; exit 1; }
  ensure_postgres_installed || warn "PostgreSQL setup skipped or failed; ensure DB is reachable per .env."
    if [[ "$no_build" != true ]]; then
      build_binary
    else
      warn "Skipping build due to --no-build"
    fi
    if [[ "$no_up" != true ]]; then
      log "Running binary in foreground. Press Ctrl+C to stop."
      "$BUILD_BIN"
    else
      ok "Build complete. You can run: $BUILD_BIN"
    fi
    ;;

  *)
    err "Unknown method: $method"
    exit 1
    ;;
esac

exit 0
