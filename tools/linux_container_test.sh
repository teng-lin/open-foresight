#!/usr/bin/env bash
# Restore the build runner's exact /src; never copy a fresh checkout over it.
set -euo pipefail
: "${SOURCE_REVISION:?Exact source revision required}"
: "${OUT_UID:?Output owner required}"
: "${OUT_GID:?Output group required}"
[[ "$OUT_UID:$OUT_GID" =~ ^[0-9]+:[0-9]+$ ]]
mkdir -p /out
trap 'chown -R "$OUT_UID:$OUT_GID" /out' EXIT
source /workspace/tools/linux_tooling_python.sh
foresight_select_tooling_python /workspace
task_python=$FORESIGHT_PYTHON
"$task_python" /workspace/tools/ci_linux_handoff.py restore --root /src --directory /handoff \
  --revision "$SOURCE_REVISION" --inputs /ci-inputs.json
cd /src
export FORESIGHT_COVERAGE=1 FORESIGHT_CORE_COVERAGE_MIN=90
export FORESIGHT_LINUX_UI_TEST=1 FORESIGHT_REQUIRE_NATIVE_UI_TEST=1
export FORESIGHT_FLUTTER_EXECUTABLE=/opt/flutter/bin/flutter LIBGL_ALWAYS_SOFTWARE=1
export FORESIGHT_PARALLEL_GATES=1 FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=1
# Preserve diagnostics even when a required test fails.
task_finish() {
  mkdir -p /out/test-results /out/apps/desktop
  cp -a /src/test-results/. /out/test-results/ 2>/dev/null || true
  cp -a /src/coverage /out/ 2>/dev/null || true
  cp -a /src/apps/desktop/coverage /out/apps/desktop/ 2>/dev/null || true
  cp -a /src/build/application-no-build-plan.log /out/test-results/ 2>/dev/null || true
  cp -a /src/build/Testing/Temporary/LastTest.log /out/test-results/ 2>/dev/null || true
  chown -R "$OUT_UID:$OUT_GID" /out
}
trap task_finish EXIT
case "${FORESIGHT_LINUX_TEST_SCHEDULE:-1}" in
  1) "$task_python" tools/linux_test_schedule.py --python "$task_python" ;;
  0)
    xvfb-run -a dbus-run-session -- bash tools/build.sh --test-only
    xvfb-run -a dbus-run-session -- "$task_python" tools/integration_gates.py \
      --suite fast --native build/native/libforesight_native.so --output test-results/fast-integration
    xvfb-run -a dbus-run-session -- "$task_python" tools/platform_python_tests.py --platform linux
    ;;
  *) echo 'FORESIGHT_LINUX_TEST_SCHEDULE must be 0 or 1' >&2; exit 2 ;;
esac
"$task_python" - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('test-results/service/results.xml').getroot()
assert list(root.iter('testcase')), 'Compiled service suite did not run'
assert not list(root.iter('skipped')), 'Compiled service suite must have zero skips'
PY
