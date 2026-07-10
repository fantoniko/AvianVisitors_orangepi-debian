#!/bin/sh
set -eu

copy_dir() {
  src="$1"
  dest="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    cp -a "$src/." "$dest/"
  fi
}

clear_app_volume() {
  # Only the app volume is mounted at /srv/app in this init container. Runtime
  # assets have already been moved to their own volumes before this is called.
  find /srv/app -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

# The dedicated volumes are mounted outside /srv/app, so they survive a code
# refresh unchanged. Copy any files that predate those volumes once, before
# clearing the legacy all-in-one app volume. If this container is interrupted,
# the copy is harmlessly retried on the next deploy.
#
# Copy bundled files first; legacy runtime files deliberately win on conflicts.
copy_dir /image-app/avian/assets/illustrations /srv/generated/illustrations
copy_dir /image-app/avian/assets/references /srv/generated/references
copy_dir /image-app/avian/assets/cutouts /srv/generated/cutouts
copy_dir /image-app/avian/runtime /srv/generated/runtime

copy_dir /srv/app/avian/assets/illustrations /srv/generated/illustrations
copy_dir /srv/app/avian/assets/references /srv/generated/references
copy_dir /srv/app/avian/assets/cutouts /srv/generated/cutouts
copy_dir /srv/app/avian/runtime /srv/generated/runtime

# cp -a alone leaves files removed from Git in place. Clearing the app volume
# prevents stale full-repository checkouts and duplicate generated assets from
# accumulating across deploys.
clear_app_volume
cp -a /image-app/. /srv/app/

commit="$(tr -d '\r\n' < /image-app/SOURCE_COMMIT 2>/dev/null || printf 'unknown')"
printf 'avian app volume refreshed; source_commit=%s; generated assets remain in dedicated volumes\n' "$commit"
