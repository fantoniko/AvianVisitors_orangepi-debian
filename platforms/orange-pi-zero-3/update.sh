#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Convenience entry point for the normal post-pull update workflow. Additional
# installer flags such as --dry-run or --force-python-deps may be passed through.
exec bash "$SCRIPT_DIR/install.sh" \
  --update \
  --web-bind 0.0.0.0:8079 \
  --allow-external-web-bind \
  "$@"
