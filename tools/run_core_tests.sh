#!/usr/bin/env bash
# Reuse invocation-local analyzer compiler bundles before test isolate fanout.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dart=${FORESIGHT_DART:-dart}
task_cache=$(mktemp -d "${TMPDIR:-/tmp}/foresight-boundary-analysis.XXXXXX")
trap 'rm -rf -- "$task_cache"' EXIT
export FORESIGHT_BOUNDARY_ANALYSIS_CACHE="$task_cache"
cd "$task_root/packages/foresight_core"
# Wait for natural process completion, including asynchronous bundle writes.
"$task_dart" run tool/warm_boundary_analysis.dart
"$task_dart" test "$@"
