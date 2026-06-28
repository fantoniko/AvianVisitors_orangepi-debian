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
ENABLE_IMAGE_WORKER=0
IMAGE_WORKER_INTERVAL="1h"
IMAGE_WORKER_HOURS=24
IMAGE_WORKER_LIMIT=20
IMAGE_WORKER_SIZE="1536x1024"
IMAGE_WORKER_CUTOUT_MODEL="birefnet-general"

usage() {
  cat <<'EOF'
Usage: install.sh --birdnet-api-base URL [options]

Options:
  --birdnet-api-base URL      Orange Pi API base, e.g. http://orange-pi.local:8079/avian/api
  --web-root PATH             Web root to create (default: /srv/avian-visitors)
  --web-bind ADDR:PORT        Caddy bind address (default: 127.0.0.1:8080)
  --allow-external-web-bind   Permit non-loopback --web-bind
  --enable-image-worker       Install timer for automatic OpenClaw illustrations
  --image-worker-interval DUR Run interval for the timer (default: 1h)
  --image-worker-hours N      Recent API window to inspect (default: 24)
  --image-worker-limit N      Maximum species per run (default: 20)
  --image-worker-size SIZE    OpenClaw image size (default: 1536x1024)
  --image-worker-cutout-model rembg model for cutout.py (default: birefnet-general)
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
    --enable-image-worker) ENABLE_IMAGE_WORKER=1; shift ;;
    --image-worker-interval) IMAGE_WORKER_INTERVAL="${2:?missing duration after --image-worker-interval}"; shift 2 ;;
    --image-worker-hours) IMAGE_WORKER_HOURS="${2:?missing number after --image-worker-hours}"; shift 2 ;;
    --image-worker-limit) IMAGE_WORKER_LIMIT="${2:?missing number after --image-worker-limit}"; shift 2 ;;
    --image-worker-size) IMAGE_WORKER_SIZE="${2:?missing size after --image-worker-size}"; shift 2 ;;
    --image-worker-cutout-model) IMAGE_WORKER_CUTOUT_MODEL="${2:?missing model after --image-worker-cutout-model}"; shift 2 ;;
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
case "$IMAGE_WORKER_HOURS" in
  ''|*[!0-9]*) die "--image-worker-hours must be numeric: $IMAGE_WORKER_HOURS" ;;
esac
case "$IMAGE_WORKER_LIMIT" in
  ''|*[!0-9]*) die "--image-worker-limit must be numeric: $IMAGE_WORKER_LIMIT" ;;
esac
case "$IMAGE_WORKER_SIZE" in
  *[[:space:]]*) die "--image-worker-size must not contain whitespace" ;;
esac
case "$IMAGE_WORKER_CUTOUT_MODEL" in
  *[[:space:]]*) die "--image-worker-cutout-model must not contain whitespace" ;;
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
  if [ "$ENABLE_IMAGE_WORKER" = "1" ]; then
    for pkg in python3-venv; do
      if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing+=("$pkg")
      fi
    done
  fi
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

if [ "$ENABLE_IMAGE_WORKER" = "1" ]; then
  case "$REPO_ROOT" in
    *[[:space:]]*) die "automatic image worker requires a source path without whitespace: $REPO_ROOT" ;;
  esac
  repo_owner="$(stat -c '%U' "$REPO_ROOT")"
  repo_group="$(stat -c '%G' "$REPO_ROOT")"
  id "$repo_owner" >/dev/null 2>&1 || die "source owner is not a valid user: $repo_owner"

  venv="$REPO_ROOT/.venv-cutout"
  recent_url="http://127.0.0.1:$bind_port/avian/api/birdnet-api.php?action=recent&hours=$IMAGE_WORKER_HOURS"
  service="/etc/systemd/system/avian-visitors-image-worker.service"
  timer="/etc/systemd/system/avian-visitors-image-worker.timer"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: create venv %s as %s\n' "$venv" "$repo_owner"
    printf 'DRY-RUN: install Python requirements from %s\n' "$REPO_ROOT/avian/scripts/requirements.txt"
  else
    runuser -u "$repo_owner" -- python3 -m venv "$venv"
    runuser -u "$repo_owner" -- "$venv/bin/python" -m pip install --upgrade pip wheel
    runuser -u "$repo_owner" -- "$venv/bin/python" -m pip install -r "$REPO_ROOT/avian/scripts/requirements.txt"
    if [ ! -f "$REPO_ROOT/.env.openclaw" ]; then
      install -m 0600 -o "$repo_owner" -g "$repo_group" /dev/null "$REPO_ROOT/.env.openclaw"
      cat > "$REPO_ROOT/.env.openclaw" <<'EOF'
OPENCLAW_BASE_URL=
OPENCLAW_API_KEY=
OPENCLAW_MODEL=openclaw-image
EOF
      chown "$repo_owner:$repo_group" "$REPO_ROOT/.env.openclaw"
      printf 'INFO: created %s; fill OPENCLAW_BASE_URL and OPENCLAW_API_KEY before the timer can generate images\n' "$REPO_ROOT/.env.openclaw"
    fi
  fi

  service_tmp="$(mktemp)"
  cat > "$service_tmp" <<EOF
[Unit]
Description=AvianVisitors automatic illustration generation
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
User=$repo_owner
Group=$repo_group
WorkingDirectory=$REPO_ROOT
Environment=PYTHONUNBUFFERED=1
ExecStart=$venv/bin/python $REPO_ROOT/avian/scripts/auto_illustrate_recent.py --api-url $recent_url --provider openclaw --openclaw-size $IMAGE_WORKER_SIZE --limit $IMAGE_WORKER_LIMIT --hours $IMAGE_WORKER_HOURS --cutout-model $IMAGE_WORKER_CUTOUT_MODEL
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  timer_tmp="$(mktemp)"
  cat > "$timer_tmp" <<EOF
[Unit]
Description=Run AvianVisitors automatic illustration generation

[Timer]
OnBootSec=5min
OnUnitActiveSec=$IMAGE_WORKER_INTERVAL
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: write %s\n' "$service"
    printf 'DRY-RUN: write %s\n' "$timer"
  else
    install -D -m 0644 -o root -g root "$service_tmp" "$service"
    install -D -m 0644 -o root -g root "$timer_tmp" "$timer"
    systemctl daemon-reload
    systemctl enable --now avian-visitors-image-worker.timer
  fi
  rm -f "$service_tmp" "$timer_tmp"
fi

log "web host prepared"
log "web URL: http://$WEB_BIND/"
log "smoke test: curl 'http://127.0.0.1:$bind_port/avian/api/birdnet-api.php?action=stats'"
if [ "$ENABLE_IMAGE_WORKER" = "1" ]; then
  log "image worker timer: systemctl status avian-visitors-image-worker.timer --no-pager"
  log "manual image worker run: sudo systemctl start avian-visitors-image-worker.service"
fi
