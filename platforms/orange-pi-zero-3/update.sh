#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

# Convenience entry point for the normal post-pull update workflow. Additional
# installer flags such as --dry-run or --force-python-deps may be passed through.
exec bash "$REPO_ROOT/platforms/deploy.sh" orange-pi --update "$@"
