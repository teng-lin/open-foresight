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
    Darwin) export FORESIGHT_TEST_SQL_SUPPORT_LIBRARY="$task_support_build/native/libforesight_sql_support.dylib" ;;
    Linux) export FORESIGHT_TEST_SQL_SUPPORT_LIBRARY="$task_support_build/native/libforesight_sql_support.so" ;;
    *) echo 'Unsupported runtime-support gate host' >&2; return 2 ;;
  esac
  export FORESIGHT_HELPER="$task_support_build/services/helper/ForesightHelper"
  export FORESIGHT_TEST_HELPER="$task_support_build/services/helper/ForesightHelperTest"
}
