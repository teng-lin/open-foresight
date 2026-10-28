#!/usr/bin/env bash
# Restore the build runner's exact /src; never copy a fresh checkout over it.
set -euo pipefail
: "${SOURCE_REVISION:?Exact source revision required}"
: "${OUT_UID:?Output owner required}"
: "${OUT_GID:?Output group required}"
[[ "$OUT_UID:$OUT_GID" =~ ^[0-9]+:[0-9]+$ ]]
mkdir -p /out
trap 'chown -R "$OUT_UID:$OUT_GID" /out' EXIT
# shellcheck source=tools/linux_tooling_python.sh
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
# The original archive records bytes and modes, not a privileged test identity.
# Change only the restored root's owner; the shared wrapper validates ancestry,
# claims workspace/SDK ownership without changing bytes or modes, then drops root.
[[ "$OUT_UID" != 0 && "$OUT_GID" != 0 ]] || {
  echo 'Restored runtime tests require a non-root output owner' >&2
  exit 2
}
chown "$OUT_UID:$OUT_GID" /src
# The SDK's tool graph still names the producer's private root pub cache.
# Relocate only its verified public packages before dropping container root.
"$task_python" tools/prepare_flutter_consumer.py --workspace /src --flutter-root /opt/flutter -- \
  "$task_python" tools/run_ci_user.py --workspace /src --flutter-root /opt/flutter -- \
  bash tools/linux_container_runtime.sh
