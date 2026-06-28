#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

MODE=""
DRY_RUN=0
SKIP_PACKAGES=0
WEB_BIND=""
BIRDNET_API_BASE=""
ORANGE_PI_HOST=""
START_SERVICES=0
ALLOW_DEFAULT_AUDIO=0
WEB_ROOT=""

usage() {
  cat <<'EOF'
Usage:
  sudo bash platforms/deploy.sh orange-pi [options]
  sudo bash platforms/deploy.sh web-host [options]

Orange Pi options:
  --web-bind ADDR:PORT      API/Caddy bind (default: 0.0.0.0:8079)
  --start-services          Start BirdNET services after install
  --allow-default-audio     Permit starting services with REC_CARD=default

Web host options:
  --orange-pi-host HOST     Builds http://HOST:8079/avian/api
  --birdnet-api-base URL    Explicit Orange Pi API base URL
  --web-bind ADDR:PORT      Web UI bind (default: 0.0.0.0:8080)
  --web-root PATH           Web root (default: split-web-host installer default)

Common options:
  --skip-packages           Do not install missing apt packages
  --dry-run                 Print actions without changing the system
  -h, --help                Show help

Examples:
  sudo bash platforms/deploy.sh orange-pi
  sudo bash platforms/deploy.sh web-host --orange-pi-host op3.lc
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'INFO: %s\n' "$*"
}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
}

validate_no_space() {
  local value="$1" name="$2"
  case "$value" in
    *[[:space:]]*) die "$name must not contain whitespace" ;;
  esac
}

port_from_bind() {
  local bind="$1"
  case "$bind" in
    *:*) printf '%s\n' "${bind##*:}" ;;
    *) die "bind must include a TCP port: $bind" ;;
  esac
}

run_orange_pi() {
  need_root
  WEB_BIND="${WEB_BIND:-0.0.0.0:8079}"
  validate_no_space "$WEB_BIND" "--web-bind"

  local args=(
    "$REPO_ROOT/platforms/orange-pi-zero-3/install.sh"
    --web-bind "$WEB_BIND"
    --allow-external-web-bind
  )
  [ "$DRY_RUN" = "1" ] && args+=(--dry-run)
  [ "$SKIP_PACKAGES" = "1" ] && args+=(--skip-packages)
  [ "$START_SERVICES" = "1" ] && args+=(--start-services)
  [ "$ALLOW_DEFAULT_AUDIO" = "1" ] && args+=(--allow-default-audio)

  run bash "${args[@]}"

  info "Orange Pi API smoke test:"
  info "curl 'http://127.0.0.1:$(port_from_bind "$WEB_BIND")/avian/api/birdnet-api.php?action=stats'"
}

run_web_host() {
  need_root
  WEB_BIND="${WEB_BIND:-0.0.0.0:8080}"
  validate_no_space "$WEB_BIND" "--web-bind"

  if [ -z "$BIRDNET_API_BASE" ]; then
    [ -n "$ORANGE_PI_HOST" ] || die "web-host mode needs --orange-pi-host HOST or --birdnet-api-base URL"
    validate_no_space "$ORANGE_PI_HOST" "--orange-pi-host"
    BIRDNET_API_BASE="http://$ORANGE_PI_HOST:8079/avian/api"
  fi
  validate_no_space "$BIRDNET_API_BASE" "--birdnet-api-base"

  local args=(
    "$REPO_ROOT/platforms/split-web-host/install.sh"
    --birdnet-api-base "$BIRDNET_API_BASE"
    --web-bind "$WEB_BIND"
    --allow-external-web-bind
  )
  [ "$DRY_RUN" = "1" ] && args+=(--dry-run)
  [ "$SKIP_PACKAGES" = "1" ] && args+=(--skip-packages)
  [ -n "$WEB_ROOT" ] && args+=(--web-root "$WEB_ROOT")

  run bash "${args[@]}"

  info "Web host smoke tests:"
  info "curl '$BIRDNET_API_BASE/birdnet-api.php?action=stats'"
  info "curl 'http://127.0.0.1:$(port_from_bind "$WEB_BIND")/avian/api/birdnet-api.php?action=stats'"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

case "$1" in
  orange-pi|web-host) MODE="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) die "first argument must be orange-pi or web-host" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --web-bind) WEB_BIND="${2:?missing value after --web-bind}"; shift 2 ;;
    --orange-pi-host) ORANGE_PI_HOST="${2:?missing value after --orange-pi-host}"; shift 2 ;;
    --birdnet-api-base) BIRDNET_API_BASE="${2:?missing value after --birdnet-api-base}"; shift 2 ;;
    --web-root) WEB_ROOT="${2:?missing value after --web-root}"; shift 2 ;;
    --start-services) START_SERVICES=1; shift ;;
    --allow-default-audio) ALLOW_DEFAULT_AUDIO=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  orange-pi) run_orange_pi ;;
  web-host) run_web_host ;;
esac
