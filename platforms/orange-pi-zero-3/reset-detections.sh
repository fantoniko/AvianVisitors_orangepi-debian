#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash platforms/orange-pi-zero-3/reset-detections.sh --yes

Backs up the detection database, then removes detection rows, extracted clips,
spectrograms, and generated charts. Configuration, models, noise profiles, raw
recordings, and processed source recordings are preserved.
EOF
}

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run this script with sudo." >&2; exit 1; }
[ "${1:-}" = "--yes" ] || { usage; exit 2; }
[ -r /etc/birdnet/birdnet.conf ] || { echo "Missing /etc/birdnet/birdnet.conf" >&2; exit 1; }

# shellcheck disable=SC1091
source /etc/birdnet/birdnet.conf

: "${BIRDNET_USER:?BIRDNET_USER is missing from birdnet.conf}"
: "${RECS_DIR:?RECS_DIR is missing from birdnet.conf}"
: "${EXTRACTED:?EXTRACTED is missing from birdnet.conf}"

APP_HOME="$(getent passwd "$BIRDNET_USER" | cut -d: -f6)"
[ -n "$APP_HOME" ] || { echo "Unknown service user: $BIRDNET_USER" >&2; exit 1; }

DATA_DIR="$(readlink -f -- "$RECS_DIR")"
EXTRACTED_DIR="$(readlink -f -- "$EXTRACTED")"
EXPECTED_DATA_DIR="$(readlink -m -- "$APP_HOME/BirdSongs")"

# These checks make the recursive cleanup safe even if the configuration was
# accidentally edited. The Orange Pi deployment always keeps mutable data here.
[ "$DATA_DIR" = "$EXPECTED_DATA_DIR" ] || {
  echo "Refusing unexpected RECS_DIR: $DATA_DIR (expected $EXPECTED_DATA_DIR)" >&2
  exit 1
}
case "$EXTRACTED_DIR" in
  "$DATA_DIR"/Extracted) ;;
  *) echo "Refusing unexpected EXTRACTED path: $EXTRACTED_DIR" >&2; exit 1 ;;
esac

DB_PATH="$DATA_DIR/birds.db"
BY_DATE="$EXTRACTED_DIR/By_Date"
CHARTS="$EXTRACTED_DIR/Charts"
BACKUP_DIR="$DATA_DIR/Backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_PATH="$BACKUP_DIR/birds-before-reset-$STAMP.db"

[ -f "$DB_PATH" ] || { echo "Detection database not found: $DB_PATH" >&2; exit 1; }
sqlite3 "$DB_PATH" "SELECT 1 FROM detections LIMIT 1;" >/dev/null

analysis_was_active=0
stats_was_active=0
systemctl is-active --quiet birdnet-analysis.service && analysis_was_active=1
systemctl is-active --quiet birdnet-stats.service && stats_was_active=1

restore_services() {
  [ "$stats_was_active" = 0 ] || systemctl start birdnet-stats.service
  [ "$analysis_was_active" = 0 ] || systemctl start birdnet-analysis.service
}
trap restore_services EXIT

systemctl stop birdnet-analysis.service birdnet-stats.service 2>/dev/null || true

install -d -m 0750 -o "$BIRDNET_USER" -g "$BIRDNET_USER" "$BACKUP_DIR"
before_count="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM detections;")"
runuser -u "$BIRDNET_USER" -- sqlite3 "$DB_PATH" ".backup '$BACKUP_PATH'"
chmod 0640 "$BACKUP_PATH"

runuser -u "$BIRDNET_USER" -- sqlite3 "$DB_PATH" \
  "BEGIN IMMEDIATE; DELETE FROM detections; COMMIT; VACUUM;"

for directory in "$BY_DATE" "$CHARTS"; do
  install -d -m 0775 -o "$BIRDNET_USER" -g "$BIRDNET_USER" "$directory"
  find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
done

# Reset legacy indexes used by a few older BirdNET-Pi pages and notifications.
printf 'Date;Time;Sci_Name;Com_Name;Confidence;Lat;Lon;Cutoff;Week;Sens;Overlap\n' \
  > "$APP_HOME/BirdNET-Pi/BirdDB.txt"
chown "$BIRDNET_USER:$BIRDNET_USER" "$APP_HOME/BirdNET-Pi/BirdDB.txt"
if [ -n "${IDFILE:-}" ]; then
  : > "$IDFILE"
  chown "$BIRDNET_USER:$BIRDNET_USER" "$IDFILE"
fi

after_count="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM detections;")"
echo "Removed detection rows: $before_count"
echo "Rows remaining: $after_count"
echo "Database backup: $BACKUP_PATH"
echo "Raw and processed source recordings were preserved."
