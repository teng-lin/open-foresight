#!/usr/bin/env bash
# Independent post-native gates. Service integration runs after both finish.
set -euo pipefail
task_gate=${1:?core or desktop}
task_platform=${2:?platform}
task_build=${3:?absolute build directory}
task_python=${4:?Python executable}
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
export FORESIGHT_NATIVE_LIBRARY="$task_native"
"$task_python" "$task_root/tools/verify_toolchain_pins.py" "$task_gate"
if [[ "$task_gate" == core && -n "${FORESIGHT_DART:-}" && "$FORESIGHT_DART" != dart ]]; then
  "$task_python" "$task_root/tools/verify_toolchain_pins.py" core --dart "$FORESIGHT_DART"
fi
case "$task_gate" in
  core)
  (
    export FORESIGHT_NATIVE_LIBRARY="$task_build/native/${task_native##*/}"
    export FORESIGHT_HELPER="$task_build/services/helper/ForesightHelper"
    export FORESIGHT_TEST_HELPER="$task_build/services/helper/ForesightHelperTest"
    cd "$task_root/packages/foresight_core"
    task_reports="$task_root/test-results/$task_platform/core"
    mkdir -p "$task_reports"
    rm -f -- "$task_reports"/*.events.jsonl
    if [[ "$task_mode" != test-only ]]; then
      ci_timed "core dependency resolution" dart pub get --enforce-lockfile
    fi
    if [[ "$task_mode" != build-only ]]; then
    ci_timed "core analysis" dart analyze
    if [[ "${FORESIGHT_CORE_COVERAGE_BENCHMARK:-0}" == 1 ]]; then
      # Compare the full suite on the same host/native binaries. Keep coverage
      # enforcement and reject changed test/skip outcomes between the two runs.
      export FORESIGHT_CORE_COVERAGE_MIN=${FORESIGHT_CORE_COVERAGE_MIN:-90}
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
          ci_timed "core benchmark without coverage" "$task_root/tools/run_core_tests.sh" --file-reporter="json:$task_reports/plain.events.jsonl"
        else
          FORESIGHT_PYTHON="$task_python" ci_timed "core benchmark with coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/coverage.events.jsonl"
        fi
      done
      ci_timed "core benchmark outcome comparison" "$task_python" "$task_root/tools/compare_test_runs.py" "$task_reports/plain.events.jsonl" "$task_reports/coverage.events.jsonl"
    elif [[ "${FORESIGHT_COVERAGE:-0}" == 1 ]]; then
      ci_timed "core tests and coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/core.events.jsonl"
    else
      ci_timed "core tests" "$task_root/tools/run_core_tests.sh" --file-reporter="json:$task_reports/core.events.jsonl"
    fi
    ci_timed "core enabled-hook regression" dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source test/platform_services_test.dart --name 'crash and delay hooks'
    fi
  )
  if [[ "$task_mode" != test-only ]]; then
  mkdir -p "$task_build/application"
  ci_timed "service compilation" dart compile exe "$task_root/packages/foresight_core/bin/service.dart" -o "$task_build/application/foresight-service"
  ci_timed "MCP compilation" dart compile exe "$task_root/packages/foresight_core/bin/mcp.dart" -o "$task_build/application/foresight-mcp"
  fi
    ;;
  desktop)
    (
      cd "$task_root/apps/desktop"
      task_reports="$task_root/test-results/$task_platform/desktop"
      mkdir -p "$task_reports"
      rm -f -- "$task_reports"/*.events.jsonl
      if [[ "$task_mode" != test-only ]]; then
        ci_timed "desktop dependency resolution" flutter pub get --enforce-lockfile
      fi
      if [[ "$task_mode" != build-only ]]; then
      ci_timed "desktop analysis" flutter analyze
      task_coverage=()
      if [[ "$task_platform" == linux || "${FORESIGHT_COVERAGE:-0}" == 1 || "${FORESIGHT_DESKTOP_COVERAGE_REPORT:-0}" == 1 ]]; then
        task_coverage=(--coverage)
      fi
      ci_timed "desktop tests and coverage" flutter test --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true ${task_coverage[@]+"${task_coverage[@]}"} --file-reporter="json:$task_reports/desktop.events.jsonl"
      if [[ "$task_platform" == linux ]]; then
        python3 "$task_root/tools/check_coverage.py" coverage/lcov.info --label Desktop --minimum 90
      fi
      fi
      if [[ "$task_mode" != test-only ]]; then
        ci_timed "desktop release compilation" flutter build "$task_platform" --release
      fi
    )
    ;;
  *) echo 'Gate must be core or desktop' >&2; exit 2 ;;
esac
