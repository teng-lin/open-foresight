#!/usr/bin/env bash
# Run only on a disposable Ubuntu CI host; never configure a user's host policy.
set -euo pipefail

mkdir -p test-results/document-sandbox
for task_executable in /usr/bin/bwrap /usr/bin/pdftotext /usr/bin/unrtf; do
  if [[ ! -x "$task_executable" ]]; then
    echo "Required document import executable missing: $task_executable" >&2
    exit 1
  fi
done
command -v dart

task_probe=(/usr/bin/bwrap --unshare-all --die-with-parent --new-session
  --cap-drop ALL --ro-bind /usr /usr --ro-bind-try /lib /lib
  --ro-bind-try /lib64 /lib64 --proc /proc --dev /dev --tmpfs /tmp
  --clearenv --setenv PATH /nonexistent -- /usr/bin/true)
if ! "${task_probe[@]}" 2>test-results/document-sandbox/initial-stderr.txt; then
  cat test-results/document-sandbox/initial-stderr.txt >&2
  # Ubuntu's unprivileged-user-namespace mediation may require an explicit
  # allowance for bwrap. Keep this allowance scoped to that CI executable.
  if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
    echo "Host policy setup is restricted to disposable GitHub-hosted CI runners." >&2
    exit 1
  fi
  test -x /sbin/apparmor_parser || test -x /usr/sbin/apparmor_parser
  sudo apparmor_parser --replace packaging/ci/document-sandbox.apparmor
  "${task_probe[@]}"
fi

FORESIGHT_REQUIRE_DOCUMENT_SANDBOX=1 python3 tests/integration/test_linux_documents.py \
  LinuxDocumentImportTest.test_shipped_parser_imports_pdf_and_rtf_when_tools_exist -v \
  2>&1 | tee test-results/document-sandbox/imports.log
