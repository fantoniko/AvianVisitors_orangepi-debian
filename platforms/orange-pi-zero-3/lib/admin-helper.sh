#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"

case "$action" in
  restart-recording)
    exec /bin/systemctl restart birdnet-recording.service
    ;;
  restart-analysis)
    exec /bin/systemctl restart birdnet-analysis.service
    ;;
  restart-livestream)
    exec /bin/systemctl restart livestream.service
    ;;
  restart-stats)
    exec /bin/systemctl restart birdnet-stats.service
    ;;
  restart-spectrogram)
    exec /bin/systemctl restart spectrogram-viewer.service
    ;;
  restart-icecast2)
    exec /bin/systemctl restart icecast2.service
    ;;
  status)
    exec /bin/systemctl status --no-pager birdnet-recording.service birdnet-analysis.service livestream.service birdnet-stats.service spectrogram-viewer.service
    ;;
  *)
    printf 'Unsupported admin helper action: %s\n' "$action" >&2
    exit 64
    ;;
esac
