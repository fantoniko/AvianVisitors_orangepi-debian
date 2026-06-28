#!/bin/sh
set -eu

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

if [ -d /srv/app/avian/assets/illustrations ]; then
  mkdir -p "$tmp/avian/assets"
  cp -a /srv/app/avian/assets/illustrations "$tmp/avian/assets/illustrations"
fi

if [ -d /srv/app/avian/assets/references ]; then
  mkdir -p "$tmp/avian/assets"
  cp -a /srv/app/avian/assets/references "$tmp/avian/assets/references"
fi

cp -a /image-app/. /srv/app/

if [ -d "$tmp/avian/assets/illustrations" ]; then
  mkdir -p /srv/app/avian/assets/illustrations
  cp -a "$tmp/avian/assets/illustrations/." /srv/app/avian/assets/illustrations/
fi

if [ -d "$tmp/avian/assets/references" ]; then
  mkdir -p /srv/app/avian/assets/references
  cp -a "$tmp/avian/assets/references/." /srv/app/avian/assets/references/
fi

printf 'avian app volume refreshed; generated illustrations/references preserved\n'
