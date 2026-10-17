#!/usr/bin/env bash
# Fail on reports from any test or child process, including expected-exit probes.
set -euo pipefail
task_build=${1:?native build directory}
task_output=${2:?sanitizer evidence directory}
mkdir -p "$task_output"
task_output=$(cd -- "$task_output" && pwd)
# Clang's shared runtime also instruments the Python ctypes test host. Python's
# process-shutdown allocation policy is outside this address/UB gate; native
# invalid accesses and undefined behavior remain fatal in all child processes.
export LD_PRELOAD="$(clang++ -print-file-name=libclang_rt.asan-x86_64.so)${LD_PRELOAD:+:$LD_PRELOAD}"
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:abort_on_error=1:log_path=$task_output/asan"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1:log_path=$task_output/ubsan"
task_result=0
ctest --test-dir "$task_build" --output-on-failure --timeout 120 \
  --output-junit "$task_output/junit.xml" > "$task_output/ctest.log" 2>&1 || task_result=$?
cat "$task_output/ctest.log"
if compgen -G "$task_output/asan.*" > /dev/null || compgen -G "$task_output/ubsan.*" > /dev/null; then
  echo 'A sanitizer reported an error, including in a child process.' >&2
  exit 1
fi
exit "$task_result"
