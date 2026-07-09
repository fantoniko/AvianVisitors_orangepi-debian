#!/bin/sh
set -eu

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

preserve_dir() {
  src="$1"
  name="$2"
  if [ -d "$src" ]; then
    mkdir -p "$tmp/$name"
    cp -a "$src/." "$tmp/$name/"
  fi
}

restore_dir() {
  src="$1"
  dest="$2"
  mkdir -p "$dest"
  if [ -d "$src" ]; then
    cp -a "$src/." "$dest/"
  fi
}

# Preserve from both the dedicated runtime volumes and the older all-in-one
# app volume layout. This migrates existing generated images on the first
# deploy after introducing the dedicated volumes.
preserve_dir /srv/generated/illustrations illustrations
preserve_dir /srv/app/avian/assets/illustrations illustrations
preserve_dir /srv/generated/references references
preserve_dir /srv/app/avian/assets/references references
preserve_dir /srv/generated/runtime runtime
preserve_dir /srv/app/avian/runtime runtime

cp -a /image-app/. /srv/app/

# Put preserved runtime-generated files back after refreshing tracked code.
# The repository intentionally ships without pre-generated illustration PNGs.
restore_dir "$tmp/illustrations" /srv/generated/illustrations
restore_dir /image-app/avian/assets/references /srv/generated/references
restore_dir "$tmp/references" /srv/generated/references
restore_dir "$tmp/runtime" /srv/generated/runtime

printf 'avian app volume refreshed; generated illustrations/references/runtime preserved in dedicated volumes\n'
