#!/bin/sh
set -eu

interval="${AV_IMAGE_WORKER_INTERVAL_SECONDS:-3600}"
start_delay="${AV_IMAGE_WORKER_START_DELAY_SECONDS:-300}"
run_on_start="${AV_IMAGE_WORKER_RUN_ON_START:-1}"
api_url="${AV_RECENT_API_URL:-http://avian-web:8080/avian/api/birdnet-api.php?action=recent&hours=24}"
state_path="${AV_IMAGE_WORKER_STATE:-/srv/app/avian/runtime/image-worker-state.json}"
failure_cooldown="${AV_IMAGE_WORKER_FAILURE_COOLDOWN_SECONDS:-86400}"
limit="${AV_IMAGE_WORKER_LIMIT:-20}"
size="${AV_IMAGE_WORKER_SIZE:-1536x1024}"
cutout_model="${AV_IMAGE_WORKER_CUTOUT_MODEL:-u2netp}"
host_uid="${AV_HOST_UID:-1000}"
host_gid="${AV_HOST_GID:-1000}"
chown_enabled="${AV_IMAGE_WORKER_CHOWN:-0}"
active_start="${AV_IMAGE_WORKER_ACTIVE_START:-08:00}"
active_end="${AV_IMAGE_WORKER_ACTIVE_END:-22:00}"

export OMP_NUM_THREADS="${AV_ONNX_THREADS:-2}"
export OPENBLAS_NUM_THREADS="${AV_ONNX_THREADS:-2}"
export MKL_NUM_THREADS="${AV_ONNX_THREADS:-2}"
export NUMEXPR_NUM_THREADS="${AV_ONNX_THREADS:-2}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

log_runtime_limits() {
  echo "worker runtime: cutout_model=$cutout_model size=$size limit=$limit active=$active_start-$active_end threads=${AV_ONNX_THREADS:-2} malloc_arena=$MALLOC_ARENA_MAX"
  echo "worker runtime: nproc=$(nproc 2>/dev/null || echo unknown)"
  if command -v free >/dev/null 2>&1; then
    free -h | sed 's/^/worker memory: /'
  fi
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current /sys/fs/cgroup/pids.max; do
    if [ -r "$f" ]; then
      echo "worker cgroup: $(basename "$f")=$(cat "$f")"
    fi
  done
}

run_once() {
  date -Is
  log_runtime_limits
  if python /srv/app/avian/scripts/auto_illustrate_recent.py \
      --api-url "$api_url" \
      --provider openclaw \
      --openclaw-size "$size" \
      --limit "$limit" \
      --state "$state_path" \
      --failure-cooldown-seconds "$failure_cooldown" \
      --active-start "$active_start" \
      --active-end "$active_end" \
      --cutout-retries "${AV_IMAGE_WORKER_CUTOUT_RETRIES:-1}" \
      --cutout-retry-delay "${AV_IMAGE_WORKER_CUTOUT_RETRY_DELAY:-15}" \
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
