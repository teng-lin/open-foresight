#!/usr/bin/env bash
# Load only on disposable hosted CI. Never install this policy in a package.
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
  echo 'Package sandbox policy setup requires a disposable GitHub-hosted runner.' >&2
  exit 1
fi
# Generic apparmor=unconfined still receives Ubuntu's unprivileged-userns
# restrictions. Docker explicitly selects this named userns-allowing profile.
sudo apparmor_parser --replace packaging/ci/document-sandbox.apparmor
