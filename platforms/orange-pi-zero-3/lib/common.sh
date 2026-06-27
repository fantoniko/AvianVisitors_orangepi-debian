#!/usr/bin/env bash

set -Eeuo pipefail

AV_PLATFORM_NAME="orange-pi-zero-3"
AV_DEFAULT_USER="avianvisitors"
AV_DEFAULT_WEB_BIND="127.0.0.1:8079"
AV_MANIFEST_DIR="/var/lib/avian-visitors/install"
AV_BACKUP_DIR="/var/backups/avian-visitors"
AV_PREFIX_MARKER=".avian-visitors-orange-pi-zero-3"

log_info() {
  printf 'INFO: %s\n' "$*"
}

log_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

log_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

require_root() {
  is_root || die "Run this script as root. Use --dry-run to preview without changing the system."
}

repo_root_from_script() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  cd -- "$script_dir/../.." && pwd -P
}

timestamp_utc() {
  date -u '+%Y%m%dT%H%M%SZ'
}

quote_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

run_cmd() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_as_user() {
  local user="$1"
  shift
  run_cmd runuser -u "$user" -- "$@"
}

path_is_under() {
  local path="$1"
  local parent="$2"
  case "$path" in
    "$parent"|"$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_service_user() {
  local user="$1"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid service user name: $user"
}

validate_absolute_path() {
  local value="$1"
  local label="$2"
  case "$value" in
    /*) ;;
    *) die "$label must be an absolute path: $value" ;;
  esac
}

validate_no_whitespace() {
  local value="$1"
  local label="$2"
  if [[ "$value" =~ [[:space:]] ]]; then
    die "$label must not contain whitespace: $value"
  fi
}

append_manifest() {
  local path="$1"
  [ -n "${MANIFEST_FILE:-}" ] || return 0
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: manifest add %s\n' "$path"
  else
    printf '%s\n' "$path" >> "$MANIFEST_FILE"
  fi
}

ensure_dir() {
  local path="$1"
  local mode="${2:-0755}"
  local owner="${3:-root:root}"
  run_cmd install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$path"
  append_manifest "$path"
}

backup_file() {
  local path="$1"
  [ -e "$path" ] || return 0
  local backup_root="${BACKUP_ROOT:?}"
  local target="$backup_root${path}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: backup %s -> %s\n' "$path" "$target"
    return 0
  fi
  install -d -m 0750 "$(dirname "$target")"
  cp -a -- "$path" "$target"
  printf '%s\t%s\n' "$path" "$target" >> "$BACKUP_ROOT/backup-map.tsv"
}

copy_file_as_user() {
  local src="$1"
  local dst="$2"
  local user="$3"
  local mode="${4:-0644}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: install %s -> %s owner=%s mode=%s\n' "$src" "$dst" "$user:$user" "$mode"
    return 0
  fi
  install -D -m "$mode" -o "$user" -g "$user" "$src" "$dst"
  append_manifest "$dst"
}

write_file_from_stdin() {
  local path="$1"
  local mode="${2:-0644}"
  local owner="${3:-root:root}"
  backup_file "$path"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: write %s mode=%s owner=%s\n' "$path" "$mode" "$owner"
    cat >/dev/null
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  append_manifest "$path"
}

service_unit_path() {
  printf '/etc/systemd/system/%s\n' "$1"
}

detect_php_fpm_service() {
  systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null |
    awk 'NR == 1 {print $1}'
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}
