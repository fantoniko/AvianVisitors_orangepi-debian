#!/usr/bin/env bash
# Run this on the Docker/Portainer web host:
#   bash scripts/verify-web-host.sh
#
# Change only the CONFIGURATION values. No tokens or API keys are required.

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

WEB_URL="http://127.0.0.1:8080"
COMPOSE_PROJECT="avian-visitors"
CHECK_POCKETFRAME=0

###############################################################################

PASS=0
FAIL=0
SKIP=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; RESET=""
fi

ok()   { PASS=$((PASS + 1)); printf '%bSUCCESS%b  %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '%bFAIL%b     %s\n' "$RED" "$RESET" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '%bSKIP%b     %s\n' "$YELLOW" "$RESET" "$1"; }

http_check() {
  local title="$1" url="$2" needle="$3" body="$TMP_DIR/response-$RANDOM"
  local status
  status=$(curl -sS --connect-timeout 3 --max-time 10 -o "$body" -w '%{http_code}' "$url" 2>"$body.err") || status=000
  if [ "$status" = 200 ] && grep -Fq "$needle" "$body"; then
    ok "$title (HTTP 200)"
  else
    bad "$title (HTTP $status)"
    if [ -s "$body.err" ]; then sed 's/^/           /' "$body.err"; fi
    if [ -s "$body" ]; then head -c 300 "$body" | tr '\n' ' '; printf '\n'; fi
  fi
}

service_id() {
  docker ps -aq \
    --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}

healthy_service() {
  local service="$1" id state
  id=$(service_id "$service")
  if [ -z "$id" ]; then
    bad "Docker service $service exists in project $COMPOSE_PROJECT"
    return
  fi
  state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
  if [ "$state" = "running healthy" ]; then
    ok "Docker service $service is running and healthy"
  else
    bad "Docker service $service status is $state"
    docker logs --tail 30 "$id" 2>&1 | sed 's/^/           /'
  fi
}

running_service() {
  local service="$1" id state
  id=$(service_id "$service")
  if [ -z "$id" ]; then
    bad "Docker service $service exists in project $COMPOSE_PROJECT"
    return
  fi
  state=$(docker inspect -f '{{.State.Status}}' "$id")
  if [ "$state" = "running" ]; then
    ok "Docker service $service is running"
  else
    bad "Docker service $service status is $state"
    docker logs --tail 30 "$id" 2>&1 | sed 's/^/           /'
  fi
}

app_init_service() {
  local id state
  id=$(service_id avian-app-init)
  if [ -z "$id" ]; then
    bad "Docker service avian-app-init exists in project $COMPOSE_PROJECT"
    return
  fi
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$id")
  if [ "$state" = "exited 0" ]; then
    ok "Docker service avian-app-init completed successfully"
  else
    bad "Docker service avian-app-init status is $state"
    docker logs --tail 30 "$id" 2>&1 | sed 's/^/           /'
  fi
}

worker_api() {
  local id
  id=$(service_id avian-worker)
  if [ -z "$id" ]; then
    bad "Worker can query its internal recent-detections API"
    return
  fi
  if docker exec "$id" python -c 'import json, os, urllib.request
u = os.environ["AV_RECENT_API_URL"]
assert "species" in json.load(urllib.request.urlopen(u, timeout=10))' >/dev/null 2>&1; then
    ok "Worker can query its internal recent-detections API"
  else
    bad "Worker can query its internal recent-detections API"
    docker logs --tail 50 "$id" 2>&1 | sed 's/^/           /'
  fi
}

printf 'AvianVisitors web-host verification\nURL: %s\n\n' "$WEB_URL"

if ! command -v curl >/dev/null 2>&1; then
  bad "curl is installed"
else
  echo "=== Web application ==="
  http_check "Collage frontend responds" "$WEB_URL/" '<!doctype html'
  http_check "Web proxy stats endpoint" "$WEB_URL/avian/api/birdnet-api.php?action=stats" '"totals"'
  http_check "Web proxy recent endpoint" "$WEB_URL/avian/api/birdnet-api.php?action=recent&hours=24" '"species"'
  http_check "Web proxy timeseries endpoint" "$WEB_URL/avian/api/birdnet-api.php?action=timeseries&days=7" '"daily"'
fi

echo
echo "=== Docker / Portainer services ==="
if ! command -v docker >/dev/null 2>&1; then
  bad "docker command is available"
elif ! docker info >/dev/null 2>&1; then
  bad "Current user can connect to Docker"
else
  app_init_service
  healthy_service avian-web
  healthy_service avian-php
  healthy_service avian-worker
  worker_api
  if [ "$CHECK_POCKETFRAME" = 1 ]; then
    running_service avian-pocketframe
  else
    skip "PocketFrame is disabled (set CHECK_POCKETFRAME=1 when enabled)"
  fi
fi

echo
printf '=== Summary ===\n%bSUCCESS%b: %d  %bFAIL%b: %d  %bSKIP%b: %d\n' \
  "$GREEN" "$RESET" "$PASS" "$RED" "$RESET" "$FAIL" "$YELLOW" "$RESET" "$SKIP"
[ "$FAIL" -eq 0 ]
