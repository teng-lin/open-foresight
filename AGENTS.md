# Agent instructions

Use [CONTRIBUTING.md](CONTRIBUTING.md) for setup, conventions and required checks.

- Integrate small, independently verified batches, even when delivering one PR.
- Reproduce the exact failed CI entrypoint. Match OS, pinned tools, UID/GID,
  NSS account/home, caches, network isolation and source/JIT mode. Record gaps.
- Exercise the actual consumer; metadata checks and quiet component replays
  prove only their own scope.
- Give each failure an owner, a bounded investigation and a concrete exit
  criterion. Confirm delegated agents are active.
- Before another push, fetch the PR head, reviews and CI output; batch fixes
  against current code. Rerun failed jobs first.
- Distinguish implemented, locally verified and CI-passed. Report source
  revisions, test counts, skips and unexecuted environments. Retain failed output.
- Preserve tests, deadlines, coverage and integrity gates. Reuse verified SDKs;
  avoid unrelated cache deletion, clean builds and successful-job reruns.
- Use short, private `/var/tmp` directories with `TMPDIR` and
  `FORESIGHT_TEST_TEMP_ROOT` set.
- Follow [CI integrity](docs/platforms/ci-integrity.md), including owner review
  for workflow permissions, publishing and artifact-trust changes.
