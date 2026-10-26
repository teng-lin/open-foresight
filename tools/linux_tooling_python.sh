#!/usr/bin/env bash
# Build/test tooling is separate from the SDK's model-runtime environments.
foresight_select_tooling_python() {
  local task_tooling_root=${1:?source root}
  local task_tooling_runtime=${FORESIGHT_TOOLING_PYTHON_RUNTIME:-}
  local task_tooling_python=${FORESIGHT_PYTHON:-/opt/dev-python/bin/python}
  if [[ -n "$task_tooling_runtime" ]]; then
    "$task_tooling_runtime" -I -c 'import sys; assert sys.version_info[:2] == (3, 13), "Build tooling requires Python 3.13"' || return $?
    local task_tooling_environment
    task_tooling_environment=$(mktemp -d /var/tmp/of-tool-python.XXXXXX) || return $?
    "$task_tooling_runtime" -m venv "$task_tooling_environment" || return $?
    task_tooling_python="$task_tooling_environment/bin/python"
    "$task_tooling_python" -m pip install --require-hashes -r "$task_tooling_root/requirements-dev.lock" || return $?
  fi
  "$task_tooling_python" -I -c 'import sys, pytest, yaml; assert sys.version_info[:2] == (3, 13), "Build tooling requires Python 3.13"' || return $?
  export FORESIGHT_PYTHON="$task_tooling_python"
}
