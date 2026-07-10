#!/usr/bin/env bash
# Run this directly on the Orange Pi:
#   bash scripts/verify-orange-pi.sh
#
# Change only the CONFIGURATION values.

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

PI_API_URL="http://127.0.0.1:8079/avian/api"
BIRDS_DB="/home/avianvisitors/BirdNET-Pi/scripts/birds.db"

# Remove a service only when you intentionally did not deploy it.
REQUIRED_SERVICES="caddy birdnet-recording birdnet-analysis birdnet-stats livestream spectrogram-viewer"

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

http_check() {
  local title="$1" url="$2" needle="$3" body="$TMP_DIR/response-$RANDOM"
  local status
  status=$(curl -sS --connect-timeout 3 --max-time 10 -o "$body" -w '%{http_code}' "$url" 2>"$body.err") || status=000
  if [ "$status" = 200 ] && grep -Fq "$needle" "$body"; then
    ok "$title (HTTP 200)"
  else
    bad "$title (HTTP $status)"
    [ -s "$body.err" ] && sed 's/^/           /' "$body.err"
  fi
}

printf 'AvianVisitors Orange Pi verification\nAPI: %s\n\n' "$PI_API_URL"

echo "=== System services ==="
for service in $REQUIRED_SERVICES; do
  if systemctl is-active --quiet "$service"; then
    ok "Systemd service $service is active"
  else
    bad "Systemd service $service is active"
    systemctl --no-pager --full status "$service" 2>&1 | tail -n 12 | sed 's/^/           /'
  fi
done

echo
echo "=== Local API and database ==="
if command -v curl >/dev/null 2>&1; then
  http_check "Local stats endpoint" "$PI_API_URL/birdnet-api.php?action=stats" '"totals"'
  http_check "Local recent endpoint" "$PI_API_URL/birdnet-api.php?action=recent&hours=24" '"species"'
else
  bad "curl is installed"
fi

if [ -r "$BIRDS_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  count=$(sqlite3 "$BIRDS_DB" 'SELECT COUNT(*) FROM detections;' 2>/dev/null) || count=""
  if [ -n "$count" ]; then
    ok "birds.db is readable ($count detections)"
  else
    bad "birds.db query succeeds"
  fi
else
  bad "birds.db is readable and sqlite3 is installed ($BIRDS_DB)"
fi

echo
echo "=== Audio input ==="
if command -v arecord >/dev/null 2>&1 && arecord -l 2>/dev/null | grep -q card; then
  ok "An ALSA recording device is detected"
else
  bad "An ALSA recording device is detected"
  command -v arecord >/dev/null 2>&1 && arecord -l 2>&1 | sed 's/^/           /'
fi

echo
printf '=== Summary ===\n%bSUCCESS%b: %d  %bFAIL%b: %d\n' \
  "$GREEN" "$RESET" "$PASS" "$RED" "$RESET" "$FAIL"
[ "$FAIL" -eq 0 ]
