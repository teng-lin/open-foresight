#!/usr/bin/env bash
# Reuse invocation-local analyzer compiler bundles before test isolate fanout.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dart=${FORESIGHT_DART:-dart}
task_concurrency=()
if [[ ${FORESIGHT_CORE_TEST_CONCURRENCY+x} ]]; then
  if [[ ! $FORESIGHT_CORE_TEST_CONCURRENCY =~ ^[1-9][0-9]*$ ]]; then
    echo 'FORESIGHT_CORE_TEST_CONCURRENCY must be a positive integer' >&2
    exit 2
  fi
  task_explicit=0
  for task_arg in "$@"; do
    case "$task_arg" in
      --concurrency|--concurrency=*|-j|-j?*) task_explicit=1 ;;
    esac
  done
  if (( ! task_explicit )); then
    task_concurrency=("--concurrency=$FORESIGHT_CORE_TEST_CONCURRENCY")
  fi
fi
task_cache=$(mktemp -d "${TMPDIR:-/tmp}/foresight-boundary-analysis.XXXXXX")
trap 'rm -rf -- "$task_cache"' EXIT
export FORESIGHT_BOUNDARY_ANALYSIS_CACHE="$task_cache"
cd "$task_root/packages/foresight_core"
# Wait for natural process completion, including asynchronous bundle writes.
"$task_dart" run tool/warm_boundary_analysis.dart
if [[ ${FORESIGHT_CORE_TEST_CONCURRENCY+x} ]]; then
  cat > "$task_cache/processors.dart" <<'DART'
import 'dart:io';
void main() => stdout.writeln(Platform.numberOfProcessors);
DART
  task_processors=$("$task_dart" "$task_cache/processors.dart")
  [[ $task_processors =~ ^[1-9][0-9]*$ ]] || exit 2
  task_available=unknown
  if command -v nproc >/dev/null 2>&1; then
    task_available=$(nproc)
    [[ $task_available =~ ^[1-9][0-9]*$ ]] || exit 2
  fi
  task_budget=$FORESIGHT_CORE_TEST_CONCURRENCY
  if (( task_explicit )); then task_budget=explicit-cli; fi
  echo "Core test concurrency=$task_budget Dart-processors=$task_processors available-processors=$task_available" >&2
fi
"$task_dart" test "${task_concurrency[@]}" "$@"
