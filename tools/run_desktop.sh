#!/usr/bin/env bash
# Keep the user's visible desktop profile separate from the existing virtual session.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export FORESIGHT_DATA="${FORESIGHT_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/foresight-linux-desktop}"
export FORESIGHT_RUNTIME="${FORESIGHT_RUNTIME:-${XDG_RUNTIME_DIR:-$FORESIGHT_DATA/runtime}/foresight-linux-desktop}"
exec "$task_root/dist/foresight-linux/foresight-linux" "$@"
