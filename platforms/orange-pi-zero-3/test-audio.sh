#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${1:-/etc/birdnet/birdnet.conf}"
DURATION="${DURATION:-5}"
OUT="${OUT:-/tmp/avian-visitors-audio-test.wav}"

[ -r "$CONFIG_FILE" ] || {
  printf 'ERROR: cannot read %s\n' "$CONFIG_FILE" >&2
  exit 1
}

# shellcheck disable=SC1090
. "$CONFIG_FILE"

REC_CARD="${REC_CARD:-default}"
CHANNELS="${CHANNELS:-2}"

printf 'Recording %s seconds from ALSA device %s to %s\n' "$DURATION" "$REC_CARD" "$OUT"
arecord -D "$REC_CARD" -f S16_LE -c "$CHANNELS" -r 48000 -d "$DURATION" -t wav "$OUT"

if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error -show_entries stream=codec_name,sample_rate,channels -of default=noprint_wrappers=1 "$OUT"
elif command -v soxi >/dev/null 2>&1; then
  soxi "$OUT"
else
  printf 'WARNING: ffprobe/soxi not found; WAV file was recorded but not inspected\n' >&2
fi
