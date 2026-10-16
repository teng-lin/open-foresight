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
if command -v flutter >/dev/null; then
  (cd "$task_root/apps/desktop" && flutter pub get && flutter analyze && flutter test && flutter build linux --release)
else
  echo "Native build passed. Add Flutter to PATH to also build/test the desktop app." >&2
fi
