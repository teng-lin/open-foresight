#!/usr/bin/env bash
# Independent post-native gates. Service integration runs after both finish.
set -euo pipefail
task_gate=${1:?core or desktop}
task_platform=${2:?platform}
task_build=${3:?absolute build directory}
: "${4:?Python executable}"
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
    if [[ "${FORESIGHT_COVERAGE:-0}" == 1 ]]; then
      ci_timed "core tests and coverage" "$task_root/tools/coverage_core.sh"
    else
      ci_timed "core tests" dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test
    fi
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
      ci_timed "desktop tests and coverage" flutter test --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true --coverage
      python3 "$task_root/tools/check_coverage.py" coverage/lcov.info --label Desktop --minimum 76.35
      ci_timed "desktop release compilation" flutter build "$task_platform" --release
    )
    ;;
  *) echo 'Gate must be core or desktop' >&2; exit 2 ;;
esac
