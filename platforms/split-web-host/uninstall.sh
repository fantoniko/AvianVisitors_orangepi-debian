#!/usr/bin/env bash
set -Eeuo pipefail

WEB_ROOT="/srv/avian-visitors"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --web-root) WEB_ROOT="${2:?missing path after --web-root}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      printf 'Usage: uninstall.sh [--web-root PATH] [--dry-run]\n'
      exit 0
      ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { printf 'ERROR: run as root\n' >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

case "$WEB_ROOT" in
  /srv/avian-visitors|/opt/avian-visitors/web)
    ;;
  *)
    printf 'ERROR: refusing to remove unexpected web root: %s\n' "$WEB_ROOT" >&2
    exit 1
    ;;
esac

if [ -e "$WEB_ROOT" ] && [ ! -f "$WEB_ROOT/.avian-visitors-split-web-host" ]; then
  printf 'ERROR: refusing to remove unmarked web root: %s\n' "$WEB_ROOT" >&2
  exit 1
fi

if systemctl list-unit-files avian-visitors-image-worker.timer --no-legend 2>/dev/null | grep -q .; then
  run systemctl disable --now avian-visitors-image-worker.timer
fi
run rm -f /etc/systemd/system/avian-visitors-image-worker.service
run rm -f /etc/systemd/system/avian-visitors-image-worker.timer
run rm -f /etc/caddy/Caddyfile.avian-visitors-web
if [ -f /etc/caddy/Caddyfile ]; then
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: remove import Caddyfile.avian-visitors-web from /etc/caddy/Caddyfile\n'
  else
    tmp="$(mktemp)"
    grep -v '^import Caddyfile.avian-visitors-web$' /etc/caddy/Caddyfile > "$tmp" || true
    install -m 0644 -o root -g root "$tmp" /etc/caddy/Caddyfile
    rm -f "$tmp"
  fi
fi
run rm -f /etc/php/*/fpm/pool.d/avian-visitors-web.conf
run rm -rf "$WEB_ROOT"
run systemctl daemon-reload

php_service="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
[ -n "$php_service" ] && run systemctl restart "$php_service"
run systemctl reload caddy

printf 'INFO: split web host files removed. Source checkout is left intact.\n'
