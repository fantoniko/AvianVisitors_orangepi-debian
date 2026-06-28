#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

WEB_ROOT="/srv/avian-visitors"
WEB_BIND="127.0.0.1:8080"
BIRDNET_API_BASE=""
ALLOW_EXTERNAL_WEB_BIND=0
DRY_RUN=0
SKIP_PACKAGES=0

usage() {
  cat <<'EOF'
Usage: install.sh --birdnet-api-base URL [options]

Options:
  --birdnet-api-base URL      Orange Pi API base, e.g. http://orange-pi.local:8079/avian/api
  --web-root PATH             Web root to create (default: /srv/avian-visitors)
  --web-bind ADDR:PORT        Caddy bind address (default: 127.0.0.1:8080)
  --allow-external-web-bind   Permit non-loopback --web-bind
  --skip-packages             Do not install apt packages
  --dry-run                   Print actions without changing the system
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --birdnet-api-base) BIRDNET_API_BASE="${2:?missing URL after --birdnet-api-base}"; shift 2 ;;
    --web-root) WEB_ROOT="${2:?missing path after --web-root}"; shift 2 ;;
    --web-bind) WEB_BIND="${2:?missing address after --web-bind}"; shift 2 ;;
    --allow-external-web-bind) ALLOW_EXTERNAL_WEB_BIND=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf 'INFO: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -n "$BIRDNET_API_BASE" ] || die "--birdnet-api-base is required"
case "$BIRDNET_API_BASE" in
  http://*|https://*) ;;
  *) die "--birdnet-api-base must start with http:// or https://" ;;
esac
case "$WEB_ROOT" in
  /*) ;;
  *) die "--web-root must be an absolute path" ;;
esac
case "$WEB_ROOT" in
  *[[:space:]]*) die "--web-root must not contain whitespace" ;;
esac
case "$WEB_BIND" in
  *:*) ;;
  *) die "--web-bind must include a TCP port" ;;
esac

bind_host="${WEB_BIND%:*}"
bind_port="${WEB_BIND##*:}"
case "$bind_port" in
  ''|*[!0-9]*) die "--web-bind port must be numeric: $WEB_BIND" ;;
esac
case "$bind_host" in
  127.*|localhost|"[::1]"|"::1") ;;
  *)
    [ "$ALLOW_EXTERNAL_WEB_BIND" = "1" ] ||
      die "refusing non-loopback --web-bind $WEB_BIND without --allow-external-web-bind"
    ;;
esac

[ -f "$REPO_ROOT/avian/frontend/index.html" ] || die "avian frontend not found at $REPO_ROOT"
[ -d "$REPO_ROOT/avian/api" ] || die "avian api not found at $REPO_ROOT"

if [ "$SKIP_PACKAGES" = "0" ]; then
  missing=()
  for pkg in caddy php-fpm php-curl php-sqlite3; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "required packages are already installed"
  fi
fi

php_service="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk 'NR == 1 {print $1}')"
[ -n "$php_service" ] || die "No php-fpm service found"
php_version="$(printf '%s' "$php_service" | sed -E 's/^php([0-9.]+)-fpm\.service$/\1/')"
php_pool="/etc/php/$php_version/fpm/pool.d/avian-visitors-web.conf"
socket="/run/php/avian-visitors-web.sock"
caddy_site="/etc/caddy/Caddyfile.avian-visitors-web"

run install -d -m 0755 -o root -g root "$WEB_ROOT"
run ln -sfn "$REPO_ROOT/avian/frontend/index.html" "$WEB_ROOT/index.html"
run ln -sfn "$REPO_ROOT/avian/frontend/styles.css" "$WEB_ROOT/styles.css"
run ln -sfn "$REPO_ROOT/avian/frontend/apt.js" "$WEB_ROOT/apt.js"
run ln -sfn "$REPO_ROOT/avian/frontend/masks.json" "$WEB_ROOT/masks.json"
run ln -sfn "$REPO_ROOT/avian/frontend/dims.json" "$WEB_ROOT/dims.json"
run ln -sfn "$REPO_ROOT/avian" "$WEB_ROOT/avian"
run ln -sfn "$REPO_ROOT/avian/assets/favicon.png" "$WEB_ROOT/favicon.png"
run ln -sfn "$REPO_ROOT/avian/assets/favicon.png" "$WEB_ROOT/favicon.ico"
run touch "$WEB_ROOT/.avian-visitors-split-web-host"

pool_tmp="$(mktemp)"
cat > "$pool_tmp" <<EOF
[avian-visitors-web]
user = www-data
group = www-data
listen = $socket
listen.owner = caddy
listen.group = caddy
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 20s
chdir = $WEB_ROOT
env[AV_BIRDNET_API_BASE] = $BIRDNET_API_BASE
EOF
if [ "$DRY_RUN" = "1" ]; then
  printf 'DRY-RUN: write %s\n' "$php_pool"
else
  install -D -m 0644 -o root -g root "$pool_tmp" "$php_pool"
fi
rm -f "$pool_tmp"

sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
site_tmp="$(mktemp)"
sed \
  -e "s/__AV_WEB_HOST__/$(sed_escape "$bind_host")/g" \
  -e "s/__AV_WEB_PORT__/$(sed_escape "$bind_port")/g" \
  -e "s/__AV_WEB_ROOT__/$(sed_escape "$WEB_ROOT")/g" \
  -e "s/__AV_PHP_FPM_SOCKET__/$(sed_escape "$socket")/g" \
  "$SCRIPT_DIR/config/caddy.Caddyfile.template" > "$site_tmp"
if [ "$DRY_RUN" = "1" ]; then
  printf 'DRY-RUN: write %s\n' "$caddy_site"
else
  install -D -m 0644 -o root -g root "$site_tmp" "$caddy_site"
fi
rm -f "$site_tmp"

if [ "$DRY_RUN" = "0" ]; then
  if [ -f /etc/caddy/Caddyfile ] && ! grep -q '^import Caddyfile.avian-visitors-web$' /etc/caddy/Caddyfile; then
    printf '\nimport Caddyfile.avian-visitors-web\n' >> /etc/caddy/Caddyfile
  elif [ ! -f /etc/caddy/Caddyfile ]; then
    printf 'import Caddyfile.avian-visitors-web\n' > /etc/caddy/Caddyfile
  fi
  caddy fmt --overwrite "$caddy_site"
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
fi

run systemctl restart "$php_service"
run systemctl enable caddy
run systemctl reload-or-restart caddy

log "web host prepared"
log "web URL: http://$WEB_BIND/"
log "smoke test: curl 'http://127.0.0.1:$bind_port/avian/api/birdnet-api.php?action=stats'"
