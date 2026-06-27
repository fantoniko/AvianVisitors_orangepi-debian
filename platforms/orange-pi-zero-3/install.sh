#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
APP_USER="$AV_DEFAULT_USER"
APP_HOME=""
PREFIX=""
WEB_MODE="local-caddy"
WEB_BIND="$AV_DEFAULT_WEB_BIND"
START_SERVICES=0
RUN_PREFLIGHT=1
INSTALL_PACKAGES=1
ALLOW_DEFAULT_AUDIO=0
ALLOW_EXTERNAL_WEB_BIND=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --dry-run                 Print actions without modifying the system.
  --user NAME               Dedicated service user (default: avianvisitors).
  --prefix PATH             Install path (default: /home/USER/BirdNET-Pi).
  --web-server MODE         local-caddy or none (default: local-caddy).
  --web-bind ADDR:PORT      Caddy bind address (default: 127.0.0.1:8079).
  --allow-external-web-bind Permit --web-bind on a non-loopback address.
  --start-services          Start services after validation. Default only enables them.
  --allow-default-audio     Permit starting services with REC_CARD=default.
  --skip-preflight          Do not run preflight.sh before installing.
  --skip-packages           Do not install missing apt packages.
  -h, --help                Show help.

This installer does not run package upgrades, change hostname, configure tty
login, install a web terminal, or grant the web server unrestricted sudo.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --user) APP_USER="${2:?missing name after --user}"; shift 2 ;;
    --prefix) PREFIX="${2:?missing path after --prefix}"; shift 2 ;;
    --web-server) WEB_MODE="${2:?missing mode after --web-server}"; shift 2 ;;
    --web-bind) WEB_BIND="${2:?missing address after --web-bind}"; shift 2 ;;
    --allow-external-web-bind) ALLOW_EXTERNAL_WEB_BIND=1; shift ;;
    --start-services) START_SERVICES=1; shift ;;
    --allow-default-audio) ALLOW_DEFAULT_AUDIO=1; shift ;;
    --skip-preflight) RUN_PREFLIGHT=0; shift ;;
    --skip-packages) INSTALL_PACKAGES=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "$WEB_MODE" in
  local-caddy|none) ;;
  *) die "Unsupported --web-server mode: $WEB_MODE" ;;
esac

trap 'log_error "install failed at line $LINENO while running: $BASH_COMMAND"' ERR

require_root
validate_service_user "$APP_USER"

if [ "$RUN_PREFLIGHT" = "1" ]; then
  preflight_report="$(mktemp /tmp/avian-visitors-preflight.XXXXXX.json)"
  bash "$SCRIPT_DIR/preflight.sh" --report "$preflight_report" || die "preflight found critical incompatibilities; report: $preflight_report"
fi

if id "$APP_USER" >/dev/null 2>&1; then
  APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
else
  APP_HOME="/home/$APP_USER"
  run_cmd useradd --system --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
fi

[ -n "$APP_HOME" ] || die "Could not determine home for $APP_USER"
PREFIX="${PREFIX:-$APP_HOME/BirdNET-Pi}"
DATA_DIR="$APP_HOME/BirdSongs"
EXTRACTED="$DATA_DIR/Extracted"
REPO_ROOT="$(repo_root_from_script)"

validate_absolute_path "$APP_HOME" "service user home"
validate_absolute_path "$PREFIX" "--prefix"
validate_absolute_path "$DATA_DIR" "data directory"
validate_no_whitespace "$APP_HOME" "service user home"
validate_no_whitespace "$PREFIX" "--prefix"
validate_no_whitespace "$DATA_DIR" "data directory"
validate_no_whitespace "$WEB_BIND" "--web-bind"

if ! path_is_under "$PREFIX" "$APP_HOME"; then
  die "--prefix must stay under the service user's home directory ($APP_HOME)"
fi

if ! path_is_under "$DATA_DIR" "$APP_HOME"; then
  die "data directory must stay under the service user's home directory ($APP_HOME)"
fi

detect_tflite_wheel() {
  local arch pyver
  arch="$(uname -m)"
  pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"
  case "${arch}-${pyver}" in
    aarch64-311) printf 'tflite_runtime-2.17.1-cp311-cp311-linux_aarch64.whl' ;;
    aarch64-312) printf 'tflite_runtime-2.17.1-cp312-cp312-linux_aarch64.whl' ;;
    aarch64-313) printf 'tflite_runtime-2.17.1-cp313-cp313-linux_aarch64.whl' ;;
    *) return 1 ;;
  esac
}

TFLITE_WHL="$(detect_tflite_wheel)" || die "No known tflite_runtime wheel for $(uname -m)-$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"

if [ "$DRY_RUN" = "0" ]; then
  install -d -m 0750 "$AV_MANIFEST_DIR" "$AV_BACKUP_DIR"
  MANIFEST_ROOT="$(mktemp -d "$AV_MANIFEST_DIR/$(timestamp_utc).XXXXXX")"
  BACKUP_ROOT="$(mktemp -d "$AV_BACKUP_DIR/$(timestamp_utc).XXXXXX")"
  MANIFEST_FILE="$MANIFEST_ROOT/manifest.paths"
  : > "$MANIFEST_FILE"
  {
    printf 'platform=%s\n' "$AV_PLATFORM_NAME"
    printf 'user=%s\n' "$APP_USER"
    printf 'home=%s\n' "$APP_HOME"
    printf 'prefix=%s\n' "$PREFIX"
    printf 'data_dir=%s\n' "$DATA_DIR"
    printf 'web_mode=%s\n' "$WEB_MODE"
    printf 'web_bind=%s\n' "$WEB_BIND"
    printf 'backup_root=%s\n' "$BACKUP_ROOT"
  } > "$MANIFEST_ROOT/install.env"
else
  MANIFEST_ROOT="$AV_MANIFEST_DIR/$(timestamp_utc).dry-run"
  BACKUP_ROOT="$AV_BACKUP_DIR/$(timestamp_utc).dry-run"
  MANIFEST_FILE="$MANIFEST_ROOT/manifest.paths"
fi

web_bind_port() {
  local bind="$1"
  case "$bind" in
    *:*) printf '%s\n' "${bind##*:}" ;;
    *) die "--web-bind must include a TCP port: $bind" ;;
  esac
}

web_bind_host() {
  local bind="$1"
  case "$bind" in
    \[*\]:*) printf '%s\n' "${bind%%]:*}]" ;;
    *:*) printf '%s\n' "${bind%:*}" ;;
    *) die "--web-bind must include a TCP port: $bind" ;;
  esac
}

validate_web_bind_available() {
  [ "$WEB_MODE" = "local-caddy" ] || return 0
  local host port
  host="$(web_bind_host "$WEB_BIND")"
  port="$(web_bind_port "$WEB_BIND")"
  if [ "$ALLOW_EXTERNAL_WEB_BIND" != "1" ]; then
    case "$host" in
      127.*|localhost|::1|\[::1\]) ;;
      *) die "Refusing non-loopback --web-bind $WEB_BIND without --allow-external-web-bind" ;;
    esac
  fi
  has_command ss || return 0
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid web bind port: $WEB_BIND"
  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${port}$"; then
    if [ -f /etc/caddy/Caddyfile.avian-visitors ] && grep -q "http://$WEB_BIND" /etc/caddy/Caddyfile.avian-visitors; then
      log_info "TCP port $port is already used by the existing AvianVisitors Caddy fragment"
      return 0
    fi
    die "TCP port $port is already listening; choose --web-bind with a free local port"
  fi
}

install_missing_packages() {
  [ "$INSTALL_PACKAGES" = "1" ] || return 0
  has_command apt-get || die "apt-get is required unless --skip-packages is used"
  local packages=(
    ca-certificates curl git jq lsof
    iproute2
    python3 python3-venv python3-pip
    alsa-utils ffmpeg sox libsox-fmt-mp3
    sqlite3 inotify-tools
    php-cli php-fpm php-sqlite3 php-curl php-xml php-zip php-mbstring
    icecast2
  )
  if [ "$WEB_MODE" = "local-caddy" ]; then
    packages+=(caddy)
  fi

  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    run_cmd apt-get update
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log_info "all required apt packages are already installed"
  fi
}

copy_project() {
  ensure_dir "$APP_HOME" 0750 "$APP_USER:$APP_USER"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: copy %s -> %s\n' "$REPO_ROOT" "$PREFIX"
  else
    if [ -L "$PREFIX" ]; then
      die "Refusing to install into symlink prefix: $PREFIX"
    fi
    if [ -e "$PREFIX" ] && [ ! -d "$PREFIX" ]; then
      die "Refusing to install into non-directory prefix: $PREFIX"
    fi
    if [ -e "$PREFIX" ] && [ ! -f "$PREFIX/$AV_PREFIX_MARKER" ]; then
      if find "$PREFIX" -mindepth 1 -maxdepth 1 | read -r _; then
        die "Refusing to replace non-empty unmarked prefix: $PREFIX"
      fi
    fi
    install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$PREFIX"
    tar --exclude='.git' -C "$REPO_ROOT" -cf - . | tar -C "$PREFIX" -xf -
    : > "$PREFIX/$AV_PREFIX_MARKER"
    chown -R "$APP_USER:$APP_USER" "$PREFIX"
  fi
  append_manifest "$PREFIX"
  append_manifest "$PREFIX/$AV_PREFIX_MARKER"
}

configure_python() {
  run_as_user "$APP_USER" env HOME="$APP_HOME" python3 -m venv "$PREFIX/birdnet"
  run_as_user "$APP_USER" env HOME="$APP_HOME" "$PREFIX/birdnet/bin/pip3" install --upgrade pip wheel

  local whl base_url
  whl="$TFLITE_WHL"
  base_url="https://github.com/Nachtzuster/BirdNET-Pi/releases/download/v0.1"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: prepare requirements_custom.txt with %s\n' "$whl"
  else
    runuser -u "$APP_USER" -- env HOME="$APP_HOME" curl -L -o "$PREFIX/$whl" "$base_url/$whl"
    sed "s|^tensorflow.*|$PREFIX/$whl|" "$PREFIX/requirements.txt" > "$PREFIX/requirements_custom.txt"
    chown "$APP_USER:$APP_USER" "$PREFIX/requirements_custom.txt" "$PREFIX/$whl"
  fi
  run_as_user "$APP_USER" env HOME="$APP_HOME" "$PREFIX/birdnet/bin/pip3" install -r "$PREFIX/requirements_custom.txt"
}

configure_data_and_config() {
  ensure_dir "$DATA_DIR" 0775 "$APP_USER:$APP_USER"
  ensure_dir "$DATA_DIR/StreamData" 0775 "$APP_USER:$APP_USER"
  ensure_dir "$DATA_DIR/Processed" 0775 "$APP_USER:$APP_USER"
  ensure_dir "$EXTRACTED" 0775 "$APP_USER:$APP_USER"
  ensure_dir "$EXTRACTED/By_Date" 0775 "$APP_USER:$APP_USER"
  ensure_dir "$EXTRACTED/Charts" 0775 "$APP_USER:$APP_USER"
  ensure_dir "/etc/birdnet" 0755 "root:root"

  local user_escaped home_escaped
  user_escaped="$(quote_sed_replacement "$APP_USER")"
  home_escaped="$(quote_sed_replacement "$APP_HOME")"
  sed -e "s/__AV_USER__/$user_escaped/g" -e "s/__AV_HOME__/$home_escaped/g" \
    "$SCRIPT_DIR/config/birdnet.conf.template" |
    write_file_from_stdin "$PREFIX/birdnet.conf" 0664 "$APP_USER:$APP_USER"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: link /etc/birdnet/birdnet.conf -> %s\n' "$PREFIX/birdnet.conf"
  else
    backup_file /etc/birdnet/birdnet.conf
    ln -sfn "$PREFIX/birdnet.conf" /etc/birdnet/birdnet.conf
  fi
  append_manifest /etc/birdnet/birdnet.conf

  if [ "$DRY_RUN" = "0" ]; then
    local item
    for item in "$PREFIX"/homepage/*; do
      [ -e "$item" ] || continue
      runuser -u "$APP_USER" -- ln -sfn "$item" "$EXTRACTED/"
    done
    [ -d "$PREFIX/avian" ] && runuser -u "$APP_USER" -- ln -sfn "$PREFIX/avian" "$EXTRACTED/avian"
    runuser -u "$APP_USER" -- ln -sfn "$PREFIX/scripts" "$EXTRACTED/scripts"
    runuser -u "$APP_USER" -- ln -sfn "$DATA_DIR/StreamData/spectrogram.png" "$EXTRACTED/spectrogram.png"
    if [ -f "$PREFIX/avian/assets/favicon.png" ]; then
      runuser -u "$APP_USER" -- ln -sfn "$PREFIX/avian/assets/favicon.png" "$EXTRACTED/favicon.ico"
    fi
  fi
}

render_template() {
  local src="$1"
  local user_escaped home_escaped prefix_escaped
  user_escaped="$(quote_sed_replacement "$APP_USER")"
  home_escaped="$(quote_sed_replacement "$APP_HOME")"
  prefix_escaped="$(quote_sed_replacement "$PREFIX")"
  sed \
    -e "s/__AV_USER__/$user_escaped/g" \
    -e "s/__AV_HOME__/$home_escaped/g" \
    -e "s/__AV_PREFIX__/$prefix_escaped/g" \
    "$src"
}

install_units() {
  local unit
  for unit in birdnet-recording.service birdnet-analysis.service livestream.service birdnet-stats.service spectrogram-viewer.service avian-visitors-admin-helper.service; do
    render_template "$SCRIPT_DIR/systemd/$unit.in" |
      write_file_from_stdin "$(service_unit_path "$unit")" 0644 "root:root"
  done

  if [ "$DRY_RUN" = "0" ]; then
    usermod -aG audio "$APP_USER" || true
  fi

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable birdnet-recording.service birdnet-analysis.service spectrogram-viewer.service
  if [ "$WEB_MODE" = "local-caddy" ]; then
    run_cmd systemctl enable birdnet-stats.service
  fi
  if [ "$START_SERVICES" = "1" ]; then
    if [ "$ALLOW_DEFAULT_AUDIO" != "1" ] && grep -Eq '^REC_CARD="?default"?$' "$PREFIX/birdnet.conf"; then
      die "Refusing to start services with REC_CARD=default. Set a stable ALSA PCM in /etc/birdnet/birdnet.conf or pass --allow-default-audio."
    fi
    run_cmd systemctl start birdnet-recording.service birdnet-analysis.service spectrogram-viewer.service
    [ "$WEB_MODE" = "local-caddy" ] && run_cmd systemctl start birdnet-stats.service
  fi
}

configure_web() {
  [ "$WEB_MODE" = "local-caddy" ] || return 0

  local php_service socket php_major_minor socket_escaped bind_escaped extracted_escaped
  php_service="$(detect_php_fpm_service || true)"
  [ -n "$php_service" ] || die "No php-fpm service found"
  php_major_minor="$(printf '%s' "$php_service" | sed -E 's/^php([0-9.]+)-fpm\.service$/\1/')"
  socket="/run/php/avian-visitors-fpm.sock"

  if getent passwd caddy >/dev/null 2>&1; then
    run_cmd usermod -aG "$APP_USER" caddy
  fi

  write_file_from_stdin "/etc/php/$php_major_minor/fpm/pool.d/avian-visitors.conf" 0644 "root:root" <<EOF
[avian-visitors]
user = $APP_USER
group = $APP_USER
listen = $socket
listen.owner = caddy
listen.group = caddy
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 20s
chdir = $EXTRACTED
php_admin_value[open_basedir] = $APP_HOME:/etc/birdnet:/tmp
php_admin_value[sys_temp_dir] = /tmp
EOF

  socket_escaped="$(quote_sed_replacement "$socket")"
  bind_escaped="$(quote_sed_replacement "$WEB_BIND")"
  extracted_escaped="$(quote_sed_replacement "$EXTRACTED")"
  sed \
    -e "s/__AV_WEB_BIND__/$bind_escaped/g" \
    -e "s/__AV_EXTRACTED__/$extracted_escaped/g" \
    -e "s/__AV_PHP_FPM_SOCKET__/$socket_escaped/g" \
    "$SCRIPT_DIR/config/caddy.loopback.Caddyfile.template" |
    write_file_from_stdin /etc/caddy/Caddyfile.avian-visitors 0644 "root:root"

  if [ "$DRY_RUN" = "0" ]; then
    if [ -f /etc/caddy/Caddyfile ] && ! grep -q 'import Caddyfile.avian-visitors' /etc/caddy/Caddyfile; then
      backup_file /etc/caddy/Caddyfile
      printf '\nimport Caddyfile.avian-visitors\n' >> /etc/caddy/Caddyfile
    elif [ ! -f /etc/caddy/Caddyfile ]; then
      printf 'import Caddyfile.avian-visitors\n' > /etc/caddy/Caddyfile
      append_manifest /etc/caddy/Caddyfile
    fi
    caddy fmt --overwrite /etc/caddy/Caddyfile.avian-visitors
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  else
    printf 'DRY-RUN: ensure /etc/caddy/Caddyfile imports Caddyfile.avian-visitors\n'
  fi

  run_cmd systemctl restart "$php_service"
  run_cmd systemctl enable caddy
  run_cmd systemctl reload-or-restart caddy
}

write_sudoers_helper() {
  local helper_unit="/etc/systemd/system/avian-visitors-admin-helper.service"
  write_file_from_stdin /etc/sudoers.d/020_avian-visitors-admin-helper 0440 "root:root" <<EOF
# Minimal optional helper for AvianVisitors admin actions.
# The PHP-FPM service user is not granted ALL; only this template unit may be started.
$APP_USER ALL=(root) NOPASSWD: \\
    /bin/systemctl start avian-visitors-admin-helper@restart-recording.service, \\
    /bin/systemctl start avian-visitors-admin-helper@restart-analysis.service, \\
    /bin/systemctl start avian-visitors-admin-helper@restart-livestream.service, \\
    /bin/systemctl start avian-visitors-admin-helper@restart-stats.service, \\
    /bin/systemctl start avian-visitors-admin-helper@restart-spectrogram.service, \\
    /bin/systemctl start avian-visitors-admin-helper@status.service
EOF
  if [ "$DRY_RUN" = "0" ]; then
    visudo -c -f /etc/sudoers.d/020_avian-visitors-admin-helper >/dev/null
    test -f "$helper_unit"
  fi
}

create_db_if_possible() {
  if [ -x "$PREFIX/scripts/createdb.sh" ]; then
    run_as_user "$APP_USER" env HOME="$APP_HOME" USER="$APP_USER" "$PREFIX/scripts/createdb.sh"
  fi
}

validate_web_bind_available
install_missing_packages
validate_web_bind_available
copy_project
configure_data_and_config
configure_python
install_units
configure_web
write_sudoers_helper
create_db_if_possible

log_info "installation prepared"
log_info "manifest: ${MANIFEST_FILE:-dry-run}"
log_info "backup root: ${BACKUP_ROOT:-dry-run}"
log_info "edit /etc/birdnet/birdnet.conf to set REC_CARD, LATITUDE, and LONGITUDE before starting services"
