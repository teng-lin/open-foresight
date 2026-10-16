#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Profile migration is explicit; see tools/migrate_profile.py.
exec "$task_root/dist/open-foresight/open-foresight" "$@"
