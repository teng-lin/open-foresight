#!/usr/bin/env bash
# Independent post-native gates. Service integration runs after both finish.
set -euo pipefail
task_gate=${1:?core or desktop}
task_platform=${2:?platform}
task_build=${3:?absolute build directory}
task_python=${4:?Python executable}
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$task_root/tools/ci_timing.sh"
case "$task_platform" in
  macos) task_native="$task_build/native/libforesight_native.dylib" ;;
  linux) task_native="$task_build/native/libforesight_native.so" ;;
  *) echo 'Platform must be linux or macos' >&2; exit 2 ;;
esac
case "$task_gate" in
  core)
  (
    export FORESIGHT_NATIVE_LIBRARY="$task_build/native/${task_native##*/}"
    export FORESIGHT_HELPER="$task_build/services/helper/ForesightHelper"
    cd "$task_root/packages/foresight_core"
    ci_timed "core dependency resolution" dart pub get --enforce-lockfile
    ci_timed "core analysis" dart analyze
    task_reports="$task_root/test-results/$task_platform/core"
    mkdir -p "$task_reports"
    if [[ "${FORESIGHT_CORE_COVERAGE_BENCHMARK:-0}" == 1 ]]; then
      # Compare the full suite on the same host/native binaries. Keep coverage
      # enforcement and reject changed test/skip outcomes between the two runs.
      export FORESIGHT_CORE_COVERAGE_MIN=${FORESIGHT_CORE_COVERAGE_MIN:-90}
      ci_timed "core benchmark without coverage" dart test --file-reporter="json:$task_reports/plain.events.jsonl"
      ci_timed "core benchmark with coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/coverage.events.jsonl"
      ci_timed "core benchmark outcome comparison" "$task_python" "$task_root/tools/compare_test_runs.py" "$task_reports/plain.events.jsonl" "$task_reports/coverage.events.jsonl"
    elif [[ "${FORESIGHT_COVERAGE:-0}" == 1 ]]; then
      ci_timed "core tests and coverage" "$task_root/tools/coverage_core.sh" --file-reporter="json:$task_reports/core.events.jsonl"
    else
      ci_timed "core tests" dart test --file-reporter="json:$task_reports/core.events.jsonl"
    fi
    ci_timed "core enabled-hook regression" dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source test/platform_services_test.dart --name 'crash and delay hooks'
  )
  mkdir -p "$task_build/application"
  ci_timed "service compilation" dart compile exe "$task_root/packages/foresight_core/bin/service.dart" -o "$task_build/application/foresight-service"
  ci_timed "MCP compilation" dart compile exe "$task_root/packages/foresight_core/bin/mcp.dart" -o "$task_build/application/foresight-mcp"
    ;;
  desktop)
    (
      cd "$task_root/apps/desktop"
      ci_timed "desktop dependency resolution" flutter pub get --enforce-lockfile
      ci_timed "desktop analysis" flutter analyze
      task_reports="$task_root/test-results/$task_platform/desktop"
      mkdir -p "$task_reports"
      ci_timed "desktop tests and coverage" flutter test --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true --coverage --file-reporter="json:$task_reports/desktop.events.jsonl"
      if [[ "$task_platform" == linux ]]; then
        python3 "$task_root/tools/check_coverage.py" coverage/lcov.info --label Desktop --minimum 90
      fi
      ci_timed "desktop release compilation" flutter build "$task_platform" --release
    )
    ;;
  *) echo 'Gate must be core or desktop' >&2; exit 2 ;;
esac
