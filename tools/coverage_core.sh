#!/usr/bin/env bash
# Run after dart pub get; pass optional dart test arguments through unchanged.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dart=${FORESIGHT_DART:-dart}
task_output="$task_root/coverage/core"
mkdir -p "$task_output"
rm -f -- "$task_output/lcov.info"
task_raw=$(mktemp -d "$task_output/raw.XXXXXX")
trap 'rm -rf -- "$task_raw"' EXIT
cd "$task_root/packages/foresight_core"
"$task_dart" test --coverage="$task_raw" "$@"
"$task_dart" run coverage:format_coverage --lcov --in="$task_raw" \
  --out="$task_output/lcov.info" --report-on=lib \
  --ignore-files='**/generated/**' --base-directory="$task_root"

if [[ -n "${FORESIGHT_CORE_COVERAGE_MIN:-}" ]]; then
  "${FORESIGHT_PYTHON:-python3}" "$task_root/tools/check_coverage.py" \
    "$task_output/lcov.info" --minimum "$FORESIGHT_CORE_COVERAGE_MIN"
fi
