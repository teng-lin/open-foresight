#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_build=${FORESIGHT_BUILD_DIR:-"$task_root/build"}
task_python=${FORESIGHT_PYTHON:-"$task_root/.venv/bin/python"}
task_platform=${FORESIGHT_PLATFORM:-}
if [[ "${1:-}" == --platform ]]; then
  task_platform=${2:?Usage: build.sh --platform linux|macos [cmake arguments]}
  shift 2
fi
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
task_cmake_platform=()
if [[ "$task_platform" == macos ]]; then
  task_cmake_platform=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
fi
if [[ ! -x "$task_python" ]]; then
  echo "Create .venv and install --require-hashes -r requirements-dev.lock before building." >&2
  exit 1
fi
"$task_python" "$task_root/tools/verify_descriptor.py"
cmake -S "$task_root" -B "$task_build" -DCMAKE_BUILD_TYPE=Release -DPython3_EXECUTABLE="$task_python" "${task_cmake_platform[@]}" "$@"
cmake --build "$task_build" --parallel "${FORESIGHT_BUILD_JOBS:-4}"
task_build=$(cd -- "$task_build" && pwd)
ctest --test-dir "$task_build" --output-on-failure
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
  # macOS's default /var/folders temp prefix can exhaust sockaddr_un's limit
  # before the test-specific directory and socket names are appended.
  task_service_temp=$(mktemp -d /tmp/of-svc.XXXXXX)
  FORESIGHT_SERVICE_EXECUTABLE="$task_build/application/foresight-service" \
  FORESIGHT_MCP_EXECUTABLE="$task_build/application/foresight-mcp" \
  FORESIGHT_HELPER_EXECUTABLE="$task_build/services/helper/ForesightHelper" \
  FORESIGHT_NATIVE_LIBRARY="$task_native" \
    "$task_python" -m pytest "$task_root/tests/service" --basetemp "$task_service_temp" -v
  rm -rf -- "$task_service_temp"
fi
