#!/usr/bin/env bash
# Independent post-native gates. Service integration runs after both finish.
set -euo pipefail
task_gate=${1:?core or desktop}
task_platform=${2:?platform}
task_build=${3:?absolute build directory}
task_python=${4:?Python executable}
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
    dart pub get
    dart analyze
    if [[ "${FORESIGHT_COVERAGE:-0}" == 1 ]]; then
      "$task_root/tools/coverage_core.sh"
    else
      dart test
    fi
  )
  mkdir -p "$task_build/application"
  dart compile exe "$task_root/packages/foresight_core/bin/service.dart" -o "$task_build/application/foresight-service"
  dart compile exe "$task_root/packages/foresight_core/bin/mcp.dart" -o "$task_build/application/foresight-mcp"
    ;;
  desktop)
    (cd "$task_root/apps/desktop" && flutter pub get && flutter analyze && flutter test && flutter build "$task_platform" --release)
    ;;
  *) echo 'Gate must be core or desktop' >&2; exit 2 ;;
esac
