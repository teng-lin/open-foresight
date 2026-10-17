#!/usr/bin/env bash
# Collect the offline Python baseline; pass pytest arguments to narrow the run.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_python=${FORESIGHT_PYTHON:-"$task_root/.venv/bin/python"}
cd "$task_root"
"$task_python" -m pytest --cov --cov-config="$task_root/.coveragerc" \
  --cov-report=term --cov-report=html --cov-report=xml --cov-report=lcov \
  --junitxml=coverage/python/junit.xml "$@"
