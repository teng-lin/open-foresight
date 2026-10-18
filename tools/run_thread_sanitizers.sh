#!/usr/bin/env bash
set -euo pipefail
task_build=${1:?native build directory}
task_output=${2:?TSan evidence directory}
mkdir -p "$task_output"
task_output=$(cd -- "$task_output" && pwd)
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_runtime=$(python "$task_root/tools/sanitizer_runtime.py" --kind thread)
export LD_PRELOAD="$task_runtime${LD_PRELOAD:+:$LD_PRELOAD}"
export TSAN_OPTIONS="halt_on_error=1:exitcode=66:log_path=$task_output/tsan"
task_result=0
ctest --test-dir "$task_build" --output-on-failure --timeout 120 \
  --output-junit "$task_output/junit.xml" > "$task_output/ctest.log" 2>&1 || task_result=$?
cat "$task_output/ctest.log"
if compgen -G "$task_output/tsan.*" > /dev/null; then
  echo 'ThreadSanitizer reported an error; inspect retained reports.' >&2
  exit 1
fi
exit "$task_result"
