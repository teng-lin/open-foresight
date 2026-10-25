#!/usr/bin/env bash
# Native consumer gates use the finished three-product receipt, never a stamp.
# Arguments and exports are explicit build/test paths; no runtime selector opens
# a candidate library here.
foresight_verify_runtime_support() {
  local task_support_root=${1:?source root}
  local task_support_build=${2:?build root}
  local task_support_python=${3:?Python executable}
  "$task_support_python" "$task_support_root/tools/diagnostic_product_receipt.py" \
    --root "$task_support_root" --build "$task_support_build/native" --verify || return $?
  case "$(uname -s)" in
    Darwin)
      export FORESIGHT_TEST_SQL_SUPPORT_LIBRARY="$task_support_build/native/libforesight_sql_support.dylib"
      export FORESIGHT_NATIVE_LIBRARY="$task_support_build/native/libforesight_native.dylib"
      ;;
    Linux)
      export FORESIGHT_TEST_SQL_SUPPORT_LIBRARY="$task_support_build/native/libforesight_sql_support.so"
      export FORESIGHT_NATIVE_LIBRARY="$task_support_build/native/libforesight_native.so"
      ;;
    *) echo 'Unsupported runtime-support gate host' >&2; return 2 ;;
  esac
  export FORESIGHT_HELPER="$task_support_build/services/helper/ForesightHelper"
  export FORESIGHT_TEST_HELPER="$task_support_build/services/helper/ForesightHelperTest"
}


# The selected Dart executable is the same command used for host compilation.
# The worker helper alone owns the public define recipe and its verification.
foresight_diagnostic_worker() {
  local task_worker_root=${1:?source root}
  local task_worker_build=${2:?build root}
  local task_worker_python=${3:?Python executable}
  shift 3
  local task_worker_dart task_worker_sdk
  task_worker_dart=$(command -v dart) || return $?
  task_worker_sdk=$("$task_worker_python" -c     'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent.parent)'     "$task_worker_dart") || return $?
  "$task_worker_python" "$task_worker_root/tools/build_diagnostic_worker.py"     --root "$task_worker_root" --build "$task_worker_build"     --sdk "$task_worker_sdk"     --package-config "$task_worker_root/packages/foresight_core/.dart_tool/package_config.json"     --mode aot "$@"
}
