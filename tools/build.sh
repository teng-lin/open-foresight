#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$task_root/tools/ci_timing.sh"
task_build=${FORESIGHT_BUILD_DIR:-"$task_root/build"}
task_python=${FORESIGHT_PYTHON:-"$task_root/.venv/bin/python"}
task_platform=${FORESIGHT_PLATFORM:-}
task_stage=all
while [[ "${1:-}" == --platform || "${1:-}" == --stage ]]; do
  case "$1" in
    --platform) task_platform=${2:?Missing platform} ;;
    --stage) task_stage=${2:?Missing stage} ;;
  esac
  shift 2
done
case "$task_stage" in
  all|native|core|desktop|service) ;;
  *) echo 'Stage must be all, native, core, desktop, or service' >&2; exit 2 ;;
esac
if [[ -z "$task_platform" ]]; then
  case "$(uname -s)" in
    Darwin) task_platform=macos ;;
    Linux) task_platform=linux ;;
    *) echo "Unsupported build host" >&2; exit 2 ;;
  esac
fi
case "$task_platform" in
  macos)
    [[ "$(uname -s)" == Darwin ]] || { echo 'macOS builds require a Mac host' >&2; exit 2; }
    task_native="$task_build/native/libforesight_native.dylib" ;;
  linux) task_native="$task_build/native/libforesight_native.so" ;;
  *) echo 'Platform must be linux or macos' >&2; exit 2 ;;
esac
# Missing language SDKs must fail before an expensive native build in CI.
if [[ "${CI:-}" == true || "${FORESIGHT_REQUIRE_DART_GATES:-0}" == 1 ]]; then
  task_sdks=()
  case "$task_stage" in
    all|desktop) task_sdks=(dart flutter) ;;
    core|service) task_sdks=(dart) ;;
  esac
  # macOS ships Bash 3, where an empty array is unset under nounset.
  for task_sdk in ${task_sdks[@]+"${task_sdks[@]}"}; do
    if ! command -v "$task_sdk" >/dev/null; then
      echo "Required $task_sdk SDK is missing from PATH." >&2
      exit 1
    fi
  done
fi
task_cmake_platform=()
if [[ "$task_platform" == macos ]]; then
  task_cmake_platform=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
fi
if [[ ! -x "$task_python" ]]; then
  echo "Create .venv and install --require-hashes -r requirements-dev.lock before building." >&2
  exit 1
fi
if [[ "$task_stage" == all || "$task_stage" == native ]]; then
  "$task_python" "$task_root/tools/check_build_cache.py" "$task_build/CMakeCache.txt"
  "$task_python" "$task_root/tools/verify_descriptor.py"
  ci_timed "native configure" cmake -S "$task_root" -B "$task_build" -DCMAKE_BUILD_TYPE=Release -DPython3_EXECUTABLE="$task_python" ${task_cmake_platform[@]+"${task_cmake_platform[@]}"} "$@"
  ci_timed "native compile" cmake --build "$task_build" --parallel "${FORESIGHT_BUILD_JOBS:-4}"
  ci_timed "native tests" ctest --test-dir "$task_build" --output-on-failure
fi
task_build=$(cd -- "$task_build" && pwd)
case "$task_stage" in
  native) exit 0 ;;
  core|desktop)
    exec bash "$task_root/tools/build_dart_gates.sh" "$task_stage" "$task_platform" "$task_build" "$task_python" ;;
  service)
    exec bash "$task_root/tools/build_service_gate.sh" "$task_platform" "$task_build" "$task_python" ;;
esac
if [[ "${FORESIGHT_PARALLEL_GATES:-0}" == 1 ]] && command -v dart >/dev/null && command -v flutter >/dev/null; then
  "$task_python" "$task_root/tools/parallel_build_gates.py" \
    --platform "$task_platform" --build "$task_build" --python "$task_python"
else
  if command -v dart >/dev/null; then
    bash "$task_root/tools/build_dart_gates.sh" core "$task_platform" "$task_build" "$task_python"
  else
    echo "Add Dart to PATH to build/test the application service and MCP server." >&2
  fi
  if command -v flutter >/dev/null; then
    bash "$task_root/tools/build_dart_gates.sh" desktop "$task_platform" "$task_build" "$task_python"
  else
    echo "Native build passed. Add Flutter to PATH to also build/test the desktop app." >&2
  fi
fi
if [[ -x "$task_build/application/foresight-service" && -x "$task_build/application/foresight-mcp" ]]; then
  bash "$task_root/tools/build_service_gate.sh" "$task_platform" "$task_build" "$task_python"
fi
