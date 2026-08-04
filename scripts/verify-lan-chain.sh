#!/usr/bin/env bash
# Run this from any Linux machine on the same LAN as both hosts:
#   bash scripts/verify-lan-chain.sh
#
# Change only the CONFIGURATION values.

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

WEB_URL="http://web-host.lan:8080"
ORANGE_PI_API_URL="http://orange-pi.lan:8079/avian/api"

###############################################################################

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; RESET=""
fi

ok()  { PASS=$((PASS + 1)); printf '%bSUCCESS%b  %s\n' "$GREEN" "$RESET" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '%bFAIL%b     %s\n' "$RED" "$RESET" "$1"; }

check_url() {
  local title="$1" url="$2" needle="$3" body="$TMP_DIR/response-$RANDOM"
  local status
  status=$(curl -sS --connect-timeout 3 --max-time 10 -o "$body" -w '%{http_code}' "$url" 2>"$body.err") || status=000
  if [ "$status" = 200 ] && grep -Fq "$needle" "$body"; then
    ok "$title (HTTP 200)"
  else
    bad "$title (HTTP $status)"
    [ -s "$body.err" ] && sed 's/^/           /' "$body.err"
    [ -s "$body" ] && head -c 300 "$body" | tr '\n' ' ' && printf '\n'
  fi
}

printf 'AvianVisitors LAN end-to-end verification\nWeb: %s\nOrange Pi: %s\n\n' \
  "$WEB_URL" "$ORANGE_PI_API_URL"

if ! command -v curl >/dev/null 2>&1; then
  bad "curl is installed"
  exit 2
fi

echo "=== Web host ==="
check_url "Collage frontend is reachable" "$WEB_URL/" '<!doctype html'
check_url "Web-host proxy returns BirdNET stats" "$WEB_URL/avian/api/birdnet-api.php?action=stats" '"totals"'
check_url "Web-host proxy returns recent birds" "$WEB_URL/avian/api/birdnet-api.php?action=recent&hours=24" '"species"'

echo
echo "=== Orange Pi ==="
check_url "Orange Pi API returns stats" "$ORANGE_PI_API_URL/birdnet-api.php?action=stats" '"totals"'
check_url "Orange Pi API returns recent birds" "$ORANGE_PI_API_URL/birdnet-api.php?action=recent&hours=24" '"species"'

echo
printf '=== Summary ===\n%bSUCCESS%b: %d  %bFAIL%b: %d\n' \
  "$GREEN" "$RESET" "$PASS" "$RED" "$RESET" "$FAIL"
[ "$FAIL" -eq 0 ]
