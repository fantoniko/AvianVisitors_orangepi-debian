#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
PURGE_DATA=0
MANIFEST_ROOT=""

APP_USER=""
APP_HOME=""
PREFIX=""
DATA_DIR=""
WEB_MODE=""
WEB_BIND=""
BACKUP_ROOT=""

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--dry-run] [--manifest-dir PATH] [--purge-data]

Stops only services installed by the Orange Pi Zero 3 variant, removes only
managed files, and restores backed-up configuration. User data and recordings
are kept unless --purge-data is explicitly supplied. Packages are never removed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --manifest-dir) MANIFEST_ROOT="${2:?missing path after --manifest-dir}"; shift 2 ;;
    --purge-data) PURGE_DATA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root

if [ -z "$MANIFEST_ROOT" ]; then
  MANIFEST_ROOT="$(find "$AV_MANIFEST_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1 || true)"
fi

[ -n "$MANIFEST_ROOT" ] || die "No install manifest found under $AV_MANIFEST_DIR"
validate_absolute_path "$MANIFEST_ROOT" "--manifest-dir"
path_is_under "$MANIFEST_ROOT" "$AV_MANIFEST_DIR" || die "Refusing manifest outside $AV_MANIFEST_DIR"
[ -f "$MANIFEST_ROOT/install.env" ] || die "Missing $MANIFEST_ROOT/install.env"
[ -f "$MANIFEST_ROOT/manifest.paths" ] || die "Missing $MANIFEST_ROOT/manifest.paths"

load_install_env() {
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      user) APP_USER="$value" ;;
      home) APP_HOME="$value" ;;
      prefix) PREFIX="$value" ;;
      data_dir) DATA_DIR="$value" ;;
      web_mode) WEB_MODE="$value" ;;
      web_bind) WEB_BIND="$value" ;;
      backup_root) BACKUP_ROOT="$value" ;;
      platform|"") ;;
      *) log_warn "Ignoring unknown install.env key: $key" ;;
    esac
  done < "$MANIFEST_ROOT/install.env"
}

load_install_env

[ -n "$APP_USER" ] || die "install.env is missing user"
[ -n "$APP_HOME" ] || die "install.env is missing home"
[ -n "$PREFIX" ] || die "install.env is missing prefix"
[ -n "$DATA_DIR" ] || die "install.env is missing data_dir"
validate_service_user "$APP_USER"
validate_absolute_path "$APP_HOME" "home"
validate_absolute_path "$PREFIX" "prefix"
validate_absolute_path "$DATA_DIR" "data_dir"
validate_no_whitespace "$APP_HOME" "home"
validate_no_whitespace "$PREFIX" "prefix"
validate_no_whitespace "$DATA_DIR" "data_dir"
path_is_under "$PREFIX" "$APP_HOME" || die "Refusing prefix outside service home: $PREFIX"
path_is_under "$DATA_DIR" "$APP_HOME" || die "Refusing data_dir outside service home: $DATA_DIR"
if [ -n "$BACKUP_ROOT" ]; then
  validate_absolute_path "$BACKUP_ROOT" "backup_root"
  path_is_under "$BACKUP_ROOT" "$AV_BACKUP_DIR" || die "Refusing backup_root outside $AV_BACKUP_DIR"
fi

is_manifest_path_allowed() {
  local path="$1"
  case "$path" in
    "$PREFIX"|"$PREFIX"/*|"$APP_HOME"|"$DATA_DIR"|"$DATA_DIR"/*)
      return 0
      ;;
    /etc/birdnet|/etc/birdnet/birdnet.conf)
      return 0
      ;;
    /etc/systemd/system/birdnet-recording.service|/etc/systemd/system/birdnet-analysis.service|/etc/systemd/system/livestream.service|/etc/systemd/system/birdnet-stats.service|/etc/systemd/system/spectrogram-viewer.service|/etc/systemd/system/avian-visitors-admin-helper.service)
      return 0
      ;;
    /etc/caddy/Caddyfile|/etc/caddy/Caddyfile.avian-visitors)
      return 0
      ;;
    /etc/php/*/fpm/pool.d/avian-visitors.conf)
      return 0
      ;;
    /etc/sudoers.d/020_avian-visitors-admin-helper)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remove_file_or_empty_dir() {
  local path="$1"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: remove managed path %s\n' "$path"
  elif [ -L "$path" ] || [ -f "$path" ]; then
    rm -f -- "$path"
  elif [ -d "$path" ]; then
    rmdir --ignore-fail-on-non-empty "$path" 2>/dev/null || true
  fi
}

remove_managed_prefix() {
  [ -d "$PREFIX" ] || return 0
  [ -f "$PREFIX/$AV_PREFIX_MARKER" ] || {
    log_warn "Keeping unmarked prefix: $PREFIX"
    return 0
  }
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: remove managed prefix tree %s\n' "$PREFIX"
    return 0
  fi
  find "$PREFIX" -xdev -mindepth 1 -delete
  rmdir --ignore-fail-on-non-empty "$PREFIX" 2>/dev/null || true
}

preserve_legacy_database() {
  local source_db="$PREFIX/scripts/birds.db"
  local data_db="$DATA_DIR/birds.db"
  [ "$PURGE_DATA" != "1" ] || return 0
  [ -f "$source_db" ] && [ ! -L "$source_db" ] || return 0
  [ ! -e "$data_db" ] || die "Refusing to overwrite preserved database: $data_db"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: preserve legacy database %s -> %s\n' "$source_db" "$data_db"
    return 0
  fi
  install -d -m 0775 -o "$APP_USER" -g "$APP_USER" "$DATA_DIR"
  mv -- "$source_db" "$data_db"
  chown "$APP_USER:$APP_USER" "$data_db"
}

for svc in birdnet-recording.service birdnet-analysis.service livestream.service birdnet-stats.service spectrogram-viewer.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    run_cmd systemctl disable --now "$svc"
  fi
done

run_cmd systemctl daemon-reload

if command -v tac >/dev/null 2>&1; then
  manifest_reader=(tac "$MANIFEST_ROOT/manifest.paths")
else
  manifest_reader=(awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' "$MANIFEST_ROOT/manifest.paths")
fi

"${manifest_reader[@]}" | while IFS= read -r path; do
  [ -n "$path" ] || continue
  is_manifest_path_allowed "$path" || die "Refusing to remove unmanaged manifest path: $path"
  case "$path" in
    "$PREFIX"|"$PREFIX"/*)
      continue
      ;;
    "$DATA_DIR"|"$DATA_DIR"/*)
      if [ "$PURGE_DATA" != "1" ]; then
        printf 'KEEP: %s\n' "$path"
        continue
      fi
      ;;
  esac
  remove_file_or_empty_dir "$path"
done

preserve_legacy_database
remove_managed_prefix

if [ "$PURGE_DATA" = "1" ] && [ -d "$DATA_DIR" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: purge data tree %s\n' "$DATA_DIR"
  else
    find "$DATA_DIR" -xdev -mindepth 1 -delete
    rmdir --ignore-fail-on-non-empty "$DATA_DIR" 2>/dev/null || true
  fi
fi

if [ -n "$BACKUP_ROOT" ] && [ -f "$BACKUP_ROOT/backup-map.tsv" ]; then
  while IFS="$(printf '\t')" read -r original backup; do
    [ -n "$original" ] && [ -e "$backup" ] || continue
    is_manifest_path_allowed "$original" || die "Refusing to restore unmanaged path: $original"
    if [ "$DRY_RUN" = "1" ]; then
      printf 'DRY-RUN: restore %s -> %s\n' "$backup" "$original"
    else
      install -d -m 0755 "$(dirname "$original")"
      cp -a -- "$backup" "$original"
    fi
  done < "$BACKUP_ROOT/backup-map.tsv"
fi

run_cmd systemctl daemon-reload

cat <<EOF
Uninstall completed.
Kept data directory: $DATA_DIR
Kept service user: $APP_USER
Packages were not removed.
Use --purge-data only when recordings and the local database may be deleted.
EOF
