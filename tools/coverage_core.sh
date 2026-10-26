#!/usr/bin/env bash
# Run after dart pub get --enforce-lockfile; pass optional dart test arguments through unchanged.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dart=${FORESIGHT_DART:-dart}
task_native_build=${FORESIGHT_BUILD_DIR:-}
if [[ -z "$task_native_build" && -n "${FORESIGHT_NATIVE_LIBRARY:-}" ]]; then
  task_native_build=$(dirname -- "$(dirname -- "$FORESIGHT_NATIVE_LIBRARY")")
fi
task_native_build=${task_native_build:-"$task_root/build"}
source "$task_root/tools/runtime_support_gate.sh"
foresight_verify_runtime_support "$task_root" "$task_native_build" "${FORESIGHT_PYTHON:-python3}"
task_output="$task_root/coverage/core"
mkdir -p "$task_output"
rm -f -- "$task_output/lcov.info"
task_raw=$(mktemp -d "$task_output/raw.XXXXXX")
trap 'rm -rf -- "$task_raw"' EXIT
cd "$task_root/packages/foresight_core"
# JSON coverage otherwise collects dependencies before the formatter drops them.
"$task_root/tools/run_core_tests.sh" --coverage="$task_raw" --coverage-package='^foresight_core$' "$@"
"$task_dart" run coverage:format_coverage --lcov --in="$task_raw" \
  --out="$task_output/lcov.info" --report-on=lib \
  --ignore-files='**/generated/**' --base-directory="$task_root"

if [[ -n "${FORESIGHT_CORE_COVERAGE_MIN:-}" ]]; then
  "${FORESIGHT_PYTHON:-python3}" "$task_root/tools/check_coverage.py" \
    "$task_output/lcov.info" --minimum "$FORESIGHT_CORE_COVERAGE_MIN"
fi
