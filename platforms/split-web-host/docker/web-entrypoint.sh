#!/bin/sh
set -eu

# Caddy needs the Orange Pi origin for /stream, while PHP needs the API base
# including /avian/api. Derive the former so operators only configure one URL.
if [ -z "${AV_BIRDNET_ORIGIN:-}" ]; then
  base="${AV_BIRDNET_API_BASE:-}"
  case "$base" in
    http://*|https://*) ;;
    *) echo "AV_BIRDNET_API_BASE must start with http:// or https://" >&2; exit 1 ;;
  esac

  scheme="${base%%://*}"
  authority="${base#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    ''|*@*|*\?*|*\#*)
      echo "AV_BIRDNET_API_BASE must contain a plain host[:port] without credentials" >&2
      exit 1
      ;;
  esac
  AV_BIRDNET_ORIGIN="$scheme://$authority"
  export AV_BIRDNET_ORIGIN
fi

exec "$@"
