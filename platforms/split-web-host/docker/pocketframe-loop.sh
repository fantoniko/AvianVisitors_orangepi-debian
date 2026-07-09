#!/bin/sh
set -eu

interval="${AV_POCKETFRAME_INTERVAL_SECONDS:-900}"
source_url="${AV_POCKETFRAME_SOURCE_URL:-http://avian-web:8080}"
timeout="${AV_POCKETFRAME_TIMEOUT_SECONDS:-45}"

while :; do
  date -Is
  if python publish_pocketframe.py --base-url "$source_url" --timeout "$timeout"; then
    echo "PocketFrame publish completed"
  else
    status="$?"
    echo "PocketFrame publish failed with exit $status" >&2
  fi
  echo "PocketFrame publisher sleeping ${interval}s"
  sleep "$interval"
done
