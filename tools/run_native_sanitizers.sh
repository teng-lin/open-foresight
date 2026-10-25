#!/usr/bin/env bash
# Fail on reports from any test or child process, including expected-exit probes.
set -euo pipefail
task_build=${1:?native build directory}
task_output=${2:?sanitizer evidence directory}
mkdir -p "$task_output"
task_output=$(cd -- "$task_output" && pwd)
# Clang's shared runtime also instruments the Python ctypes test host and every
# child it starts. LeakSanitizer is enabled in all of them: PYTHONMALLOC=malloc
# keeps interpreter objects visible to its heap scan, and only policy-checked
# CPython retained-allocation frames in lsan-cpython.supp may be suppressed.
# Native invalid
# accesses, undefined behavior and leaks remain fatal in all child processes.
task_tools=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
task_runtime=$(python "$task_tools/sanitizer_runtime.py")
task_settings=$(python "$task_tools/sanitizer_settings.py" --log-directory "$task_output")
while IFS='=' read -r task_name task_value; do
  export "$task_name=$task_value"
done <<< "$task_settings"
export LD_PRELOAD="$task_runtime${LD_PRELOAD:+:$LD_PRELOAD}"
task_result=0
ctest --test-dir "$task_build" --output-on-failure --timeout 120 \
  --output-junit "$task_output/junit.xml" > "$task_output/ctest.log" 2>&1 || task_result=$?
cat "$task_output/ctest.log"
if compgen -G "$task_output/asan.*" > /dev/null || compgen -G "$task_output/ubsan.*" > /dev/null; then
  grep -l 'LeakSanitizer' "$task_output"/asan.* 2> /dev/null | sed 's/^/LeakSanitizer report: /' >&2 || true
  echo 'A sanitizer reported an error or leak, including in a child process.' >&2
  exit 1
fi
exit "$task_result"
