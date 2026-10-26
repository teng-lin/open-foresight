#!/usr/bin/env bash
# Run only after the original handoff is restored and container root is dropped.
set -euo pipefail
task_python=${FORESIGHT_PYTHON:?Selected tooling Python required}
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
