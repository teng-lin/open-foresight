#!/bin/sh
# CTest, including standalone and sanitizer builds, owns this private scratch.
set -eu
if [ "$#" -eq 0 ]; then
  echo 'A native fixture executable is required.' >&2
  exit 2
fi
if [ "${FORESIGHT_TEST_TEMP_ROOT+x}" = x ]; then
  task_parent=$FORESIGHT_TEST_TEMP_ROOT
else
  case $(uname -s) in
    Darwin) task_parent=/private/var/tmp ;;
    *) task_parent=/var/tmp ;;
  esac
fi
case $task_parent in
  /*) ;;
  *) echo 'Native fixture temp parent must be an absolute directory.' >&2; exit 2 ;;
esac
task_parent=$(CDPATH='' cd -- "$task_parent" && pwd -P)
task_scratch=$(mktemp -d "$task_parent/of-native.XXXXXX")
chmod 700 "$task_scratch"
export TMPDIR="$task_scratch" FORESIGHT_TEST_TEMP_ROOT="$task_scratch"
echo "Native fixture scratch: $task_scratch" >&2
task_result=0
"$@" || task_result=$?
if [ "$task_result" -eq 0 ]; then
  rm -rf -- "$task_scratch"
else
  echo "Failed native fixture preserved at $task_scratch" >&2
fi
exit "$task_result"
