#!/bin/sh
set -eu

interval="${AV_IMAGE_WORKER_INTERVAL_SECONDS:-3600}"
start_delay="${AV_IMAGE_WORKER_START_DELAY_SECONDS:-300}"
run_on_start="${AV_IMAGE_WORKER_RUN_ON_START:-1}"
api_url="${AV_RECENT_API_URL:-http://avian-web:8080/avian/api/birdnet-api.php?action=recent&hours=24}"
limit="${AV_IMAGE_WORKER_LIMIT:-20}"
size="${AV_IMAGE_WORKER_SIZE:-1536x1024}"
cutout_model="${AV_IMAGE_WORKER_CUTOUT_MODEL:-birefnet-general}"
host_uid="${AV_HOST_UID:-1000}"
host_gid="${AV_HOST_GID:-1000}"
chown_enabled="${AV_IMAGE_WORKER_CHOWN:-0}"

run_once() {
  date -Is
  if python /srv/app/avian/scripts/auto_illustrate_recent.py \
      --api-url "$api_url" \
      --provider openclaw \
      --openclaw-size "$size" \
      --limit "$limit" \
      --cutout-model "$cutout_model"; then
    echo "avian image worker run completed"
  else
    status="$?"
    echo "avian image worker run failed with exit $status" >&2
  fi

  if [ "$chown_enabled" = "1" ]; then
    chown -R "$host_uid:$host_gid" \
      /srv/app/avian/assets/illustrations \
      /srv/app/avian/assets/references \
      /srv/app/avian/frontend/apt.js 2>/dev/null || true
  fi
}

if [ "$start_delay" != "0" ]; then
  echo "initial worker delay ${start_delay}s"
  sleep "$start_delay"
fi

if [ "$run_on_start" != "1" ]; then
  echo "sleeping ${interval}s"
  sleep "$interval"
fi

while :; do
  run_once
  echo "sleeping ${interval}s"
  sleep "$interval"
done
