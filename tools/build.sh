#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_build=${FORESIGHT_BUILD_DIR:-"$task_root/build"}
task_python=${FORESIGHT_PYTHON:-"$task_root/.venv/bin/python"}
if [[ ! -x "$task_python" ]]; then
  echo "Create .venv and install requirements-dev.txt before building." >&2
  exit 1
fi
"$task_python" "$task_root/tools/verify_descriptor.py"
cmake -S "$task_root" -B "$task_build" -DCMAKE_BUILD_TYPE=Release -DPython3_EXECUTABLE="$task_python" "$@"
cmake --build "$task_build" --parallel "${FORESIGHT_BUILD_JOBS:-4}"
ctest --test-dir "$task_build" --output-on-failure
if command -v dart >/dev/null; then
  (cd "$task_root/packages/foresight_core" && dart pub get && dart analyze && dart test)
  mkdir -p "$task_build/application"
  dart compile exe "$task_root/packages/foresight_core/bin/service.dart" -o "$task_build/application/foresight-service"
  dart compile exe "$task_root/packages/foresight_core/bin/mcp.dart" -o "$task_build/application/foresight-mcp"
else
  echo "Add Dart to PATH to build/test the application service and MCP server." >&2
fi
if command -v flutter >/dev/null; then
  (cd "$task_root/apps/desktop" && flutter pub get && flutter analyze && flutter test && flutter build linux --release)
else
  echo "Native build passed. Add Flutter to PATH to also build/test the desktop app." >&2
fi
if [[ -x "$task_build/application/foresight-service" && -x "$task_build/application/foresight-mcp" ]]; then
  FORESIGHT_SERVICE_EXECUTABLE="$task_build/application/foresight-service" \
  FORESIGHT_MCP_EXECUTABLE="$task_build/application/foresight-mcp" \
  FORESIGHT_HELPER_EXECUTABLE="$task_build/services/helper/ForesightHelper" \
  FORESIGHT_NATIVE_LIBRARY="$task_build/native/libforesight_native.so" \
    "$task_python" -m pytest "$task_root/tests/service" -v
fi
