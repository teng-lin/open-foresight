#!/usr/bin/env bash
# Measure external build/test commands while preserving their exit status.
ci_timed() {
  local task_label=$1
  shift
  local task_started=$SECONDS
  local task_status=0
  "$@" || task_status=$?
  printf 'CI timing: %s: %ss (exit %s)\n' "$task_label" "$((SECONDS - task_started))" "$task_status"
  return "$task_status"
}
