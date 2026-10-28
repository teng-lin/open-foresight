#!/usr/bin/env bash
# Independent post-native gates. Service integration runs after both finish.
set -euo pipefail
task_gate=${1:?core or desktop}
task_platform=${2:?platform}
task_build=${3:?absolute build directory}
task_python=${4:?Python executable}
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$task_root/tools/ci_timing.sh"
task_mode=${FORESIGHT_BUILD_MODE:-all}
case "$task_mode" in all|build-only|test-only) ;; *) echo 'Unknown build mode' >&2; exit 2 ;; esac
case "$task_platform" in
  macos) task_native="$task_build/native/libforesight_native.dylib" ;;
  linux) task_native="$task_build/native/libforesight_native.so" ;;
  *) echo 'Platform must be linux or macos' >&2; exit 2 ;;
esac
if [[ "$task_platform" == macos ]]; then
  export FORESIGHT_SQLITE_LIBRARY="$task_build/macos/libforesight_sqlite3.dylib"
  [[ -f "$FORESIGHT_SQLITE_LIBRARY" ]] || {
    echo "Missing application SQLite runtime: $FORESIGHT_SQLITE_LIBRARY; build foresight_sqlite3 first" >&2
    exit 1
  }
fi
source "$task_root/tools/runtime_support_gate.sh"
foresight_verify_runtime_support "$task_root" "$task_build" "$task_python"
task_source_build=$(cd -- "$task_build" && pwd -P)

export FORESIGHT_NATIVE_LIBRARY="$task_native"
"$task_python" "$task_root/tools/verify_toolchain_pins.py" "$task_gate"
if [[ "$task_gate" == core && -n "${FORESIGHT_DART:-}" && "$FORESIGHT_DART" != dart ]]; then
  "$task_python" "$task_root/tools/verify_toolchain_pins.py" core --dart "$FORESIGHT_DART"
fi
task_reports="$task_root/test-results/$task_platform/$task_gate"
mkdir -p "$task_reports"
task_checks=$(mktemp -d "$task_reports/checks.XXXXXX")
task_failed=0
task_check_index=0
# Preserve old event output before this invocation creates the canonical reports.
for task_previous in "$task_reports"/*.events.jsonl; do
  if [[ -f "$task_previous" ]]; then
    mv -- "$task_previous" "$task_checks/previous-${task_previous##*/}.raw"
  fi
done
task_run() {
  local task_label=$1 task_code=0
  shift
  task_check_index=$((task_check_index + 1))
  local task_log="$task_checks/$task_check_index.log"
  local task_pipe_status=()
  printf 'Starting %s; log %s\n' "$task_label" "$task_log"
  if ci_timed "$task_label" "$@" 2>&1 | tee "$task_log"; then
    task_pipe_status=("${PIPESTATUS[@]}")
  else
    task_pipe_status=("${PIPESTATUS[@]}")
  fi
  task_code=${task_pipe_status[0]}
  if [[ "${task_pipe_status[1]}" != 0 ]]; then
    printf 'Log streaming failed for %s (exit %s)\n' "$task_label" "${task_pipe_status[1]}" >&2
    if [[ "$task_code" == 0 ]]; then task_code=${task_pipe_status[1]}; fi
  fi
  if [[ "$task_code" != 0 ]]; then task_failed=1; fi
  printf '::group::%s (exit %s; log %s)\n' "$task_label" "$task_code" "$task_log"
  printf '::endgroup::\n'
  printf '%s\t%s\t%s\n' "$task_code" "$task_label" "$task_log" >> "$task_checks/summary.tsv"
  return "$task_code"
}
task_check() { task_run "$@" || :; }
task_require() { task_run "$@" || exit "$?"; }
case "$task_gate" in
  core)
    export FORESIGHT_HELPER="$task_build/services/helper/ForesightHelper"
    export FORESIGHT_TEST_HELPER="$task_build/services/helper/ForesightHelperTest"
    cd "$task_root/packages/foresight_core"
    if [[ "$task_mode" != test-only ]]; then
      task_require "core dependency resolution" dart pub get --enforce-lockfile
    fi
    if [[ "$task_mode" != build-only ]]; then
      task_check "core analysis" dart analyze
      task_check "core format" dart format --output=none --set-exit-if-changed .
    fi
    if [[ "$task_mode" != build-only && "${FORESIGHT_CORE_COVERAGE_BENCHMARK:-0}" == 1 ]]; then
      task_benchmark_run=${GITHUB_RUN_NUMBER:-0}
      task_benchmark_attempt=${GITHUB_RUN_ATTEMPT:-1}
      for task_benchmark_value in "$task_benchmark_run" "$task_benchmark_attempt"; do
        if [[ ! "$task_benchmark_value" =~ ^[0-9]+$ ]]; then
          echo 'Core benchmark requires decimal GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT values.' >&2
          exit 2
        fi
      done
      if [[ "$task_benchmark_attempt" =~ ^0+$ ]]; then
        echo 'Core benchmark GITHUB_RUN_ATTEMPT must be positive.' >&2
        exit 2
      fi
    fi
    task_worker_ready=0
    if [[ "$task_mode" == test-only ]]; then
      if task_run "diagnostic worker verification" foresight_diagnostic_worker "$task_root" "$task_source_build" "$task_python" --verify; then
        task_worker_ready=1
      fi
    elif task_run "diagnostic worker compilation" foresight_diagnostic_worker "$task_root" "$task_source_build" "$task_python"; then
      mkdir -p "$task_build/application"
      task_worker_gate_temp=$(mktemp -d "$task_build/application/.diagnostic-defines.XXXXXX")
      trap 'rm -rf -- "$task_worker_gate_temp"' EXIT
      if task_run "diagnostic worker verification" foresight_diagnostic_worker "$task_root" "$task_source_build" "$task_python" --verify --defines-output "$task_worker_gate_temp/defines"; then
        task_source_defines=()
        while IFS= read -r -d '' task_worker_define; do
          task_source_defines+=("$task_worker_define")
        done < "$task_worker_gate_temp/defines"
        if [[ -n ${task_source_defines[*]-} ]]; then
          task_worker_ready=1
          # Compile independently into private staging, never execute a stale
          # host after a failed compile. The parent tracks build success.
          for task_host in service mcp; do
            if task_run "$task_host compilation" dart compile exe "${task_source_defines[@]}" "$task_root/packages/foresight_core/bin/$task_host.dart" -o "$task_worker_gate_temp/foresight-$task_host"; then
              task_check "$task_host product publication" mv -- "$task_worker_gate_temp/foresight-$task_host" "$task_build/application/foresight-$task_host"
            fi
          done
        else
          echo 'Missing verified worker defines' >&2
          task_failed=1
        fi
      fi
    fi
    if [[ "$task_mode" != build-only ]]; then
      task_blocked_worker=diagnostic
      if [[ "$task_worker_ready" == 1 ]]; then
        task_blocked_worker=media
        task_media_environment="$task_checks/media-environment"
        task_media_args=(--fetch --reuse-selected)
        # The restored producer already owns a complete pinned worker build.
        # Verify that exact product offline; never rebuild after a refusal.
        # Any inherited selection (including a partial one) keeps its existing
        # strict identity validation instead of being silently replaced.
        if [[ -z ${FORESIGHT_TEST_MEDIA_WORKER+x}${FORESIGHT_TEST_MEDIA_BUILD_ID+x}${FORESIGHT_TEST_MEDIA_SHA256+x}${FORESIGHT_TEST_MEDIA_CDHASH+x} &&
              ( -e "$task_source_build/media-worker" || -L "$task_source_build/media-worker" ) ]]; then
          task_media_args+=(--existing-product "$task_source_build/media-worker")
        fi
        if task_run "media worker prerequisite" "$task_python" "$task_root/tools/run_media_test_gate.py" \
          --cache "$task_build/media-test-cache" --output "$task_checks/media-worker" \
          "${task_media_args[@]}" --environment-output "$task_media_environment"; then
          task_media_count=0
          while IFS= read -r -d '' task_media_key && IFS= read -r -d '' task_media_value; do
            case "$task_media_key" in
              FORESIGHT_TEST_MEDIA_WORKER|FORESIGHT_TEST_MEDIA_BUILD_ID|FORESIGHT_TEST_MEDIA_SHA256|FORESIGHT_TEST_MEDIA_CDHASH)
                export "$task_media_key=$task_media_value"
                task_media_count=$((task_media_count + 1)) ;;
              *) echo 'Invalid media test environment key' >&2; exit 2 ;;
            esac
          done < "$task_media_environment"
          if [[ "$task_media_count" != 4 ]]; then
            echo 'Incomplete media test environment' >&2
            task_failed=1
            task_worker_ready=0
          fi
        else
          task_worker_ready=0
        fi
      fi
      if [[ "$task_worker_ready" == 1 ]]; then
    if [[ "${FORESIGHT_CORE_COVERAGE_BENCHMARK:-0}" == 1 ]]; then
      # Compare the full suite on the same host/native binaries. Keep coverage
      # enforcement and reject changed test/skip outcomes between the two runs.
      export FORESIGHT_CORE_COVERAGE_MIN=${FORESIGHT_CORE_COVERAGE_MIN:-90}
      # Only validated single digits enter arithmetic: long/zero-padded run
      # counters cannot overflow or be interpreted as octal or shell expressions.
      task_benchmark_run_digit=${task_benchmark_run: -1}
      task_benchmark_attempt_digit=${task_benchmark_attempt: -1}
      task_benchmark_modes=(plain coverage)
      if (( (task_benchmark_run_digit + task_benchmark_attempt_digit) % 2 == 0 )); then
        task_benchmark_modes=(coverage plain)
      fi
      printf 'Core benchmark order: %s then %s (run %s, attempt %s)\n' "${task_benchmark_modes[0]}" "${task_benchmark_modes[1]}" "$task_benchmark_run" "$task_benchmark_attempt"
      for task_benchmark_mode in "${task_benchmark_modes[@]}"; do
        if [[ "$task_benchmark_mode" == plain ]]; then
          task_check "core benchmark without coverage" "$task_root/tools/run_core_tests.sh" --file-reporter="json:$task_reports/plain.events.jsonl"
        else
          FORESIGHT_PYTHON="$task_python" task_check "core benchmark with coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/coverage.events.jsonl"
        fi
      done
      task_check "core benchmark outcome comparison" "$task_python" "$task_root/tools/compare_test_runs.py" "$task_reports/plain.events.jsonl" "$task_reports/coverage.events.jsonl"
    elif [[ "${FORESIGHT_COVERAGE:-0}" == 1 ]]; then
      task_check "core tests and coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/core.events.jsonl"
    else
      task_check "core tests" "$task_root/tools/run_core_tests.sh" --file-reporter="json:$task_reports/core.events.jsonl"
    fi
      else
        echo "Blocked core suite: $task_blocked_worker worker prerequisite failed" >&2
      fi
      task_check "core enabled-hook regression" dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source test/platform_services_test.dart --name 'crash and delay hooks'
    fi
    ;;
  desktop)
    cd "$task_root/apps/desktop"
    if [[ "$task_mode" != test-only ]]; then
      task_require "desktop dependency resolution" flutter pub get --enforce-lockfile
    fi
    if [[ "$task_mode" != build-only ]]; then
      # Test-only consumes the exact verified producer dependency graph. Pub's
      # timestamp freshness check can otherwise rerun online resolution after
      # restore even when both the lock and package configuration are valid.
      task_flutter_pub=()
      if [[ "$task_mode" == test-only ]]; then task_flutter_pub=(--no-pub); fi
      task_check "desktop analysis" flutter analyze ${task_flutter_pub[@]+"${task_flutter_pub[@]}"}
      task_check "desktop format" dart format --output=none --set-exit-if-changed .
      task_coverage=()
      if [[ "$task_platform" == linux || "${FORESIGHT_COVERAGE:-0}" == 1 || "${FORESIGHT_DESKTOP_COVERAGE_REPORT:-0}" == 1 ]]; then
        task_coverage=(--coverage)
      fi
      if [[ -n ${task_coverage[*]-} && -f coverage/lcov.info ]]; then
        mv -- coverage/lcov.info "$task_checks/previous-lcov.raw"
      fi
      task_check "desktop tests and coverage" flutter test ${task_flutter_pub[@]+"${task_flutter_pub[@]}"} --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true ${task_coverage[@]+"${task_coverage[@]}"} --file-reporter="json:$task_reports/desktop.events.jsonl"
      if [[ "$task_platform" == linux ]]; then
        task_check "desktop coverage floor" "$task_python" "$task_root/tools/check_coverage.py" coverage/lcov.info --label Desktop --minimum 90
      fi
    fi
    if [[ "$task_mode" != test-only ]]; then
      task_check "desktop release compilation" flutter build "$task_platform" --release
    fi
    ;;
  *) echo 'Gate must be core or desktop' >&2; exit 2 ;;
esac
printf 'Gate outcomes (%s):\n' "$task_gate"
cat "$task_checks/summary.tsv"
exit "$task_failed"
