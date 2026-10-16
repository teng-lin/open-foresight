#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# The app resolves existing desktop profiles without moving live databases.
exec "$task_root/dist/foresight/foresight" "$@"
