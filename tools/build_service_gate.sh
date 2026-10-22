#!/usr/bin/env bash
# Run the compiled desktop-service and MCP boundary without rebuilding it.
set -euo pipefail
task_platform=${1:?platform}
task_build=${2:?absolute build directory}
task_python=${3:?Python executable}
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$task_root/tools/ci_timing.sh"
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
for task_binary in "$task_build/application/foresight-service" "$task_build/application/foresight-mcp" "$task_build/services/helper/ForesightHelper" "$task_build/services/helper/model_worker_fixture"; do
  [[ -f "$task_binary" ]] || { echo "Missing stage prerequisite: $task_binary" >&2; exit 1; }
  [[ -x "$task_binary" ]] || { echo "Stage prerequisite is not executable: $task_binary" >&2; exit 1; }
done
[[ -f "$task_native" ]] || { echo "Missing stage prerequisite: $task_native" >&2; exit 1; }
# Short sockets work on macOS too. Honor disk-backed local test storage.
task_service_temp=$(mktemp -d "${FORESIGHT_TEST_TEMP_ROOT:-/tmp}/of-svc.XXXXXX")
trap 'rm -rf -- "$task_service_temp"' EXIT
mkdir -p "$task_root/test-results/service"
FORESIGHT_SERVICE_EXECUTABLE="$task_build/application/foresight-service" \
FORESIGHT_MCP_EXECUTABLE="$task_build/application/foresight-mcp" \
FORESIGHT_HELPER_EXECUTABLE="$task_build/services/helper/ForesightHelper" \
FORESIGHT_NATIVE_LIBRARY="$task_native" \
  ci_timed "service and MCP integration" "$task_python" -m pytest "$task_root/tests/service" --basetemp "$task_service_temp" --junitxml="$task_root/test-results/service/results.xml" -v
