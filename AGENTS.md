# Agent instructions

Setup, test commands and conventions are in [CONTRIBUTING.md](CONTRIBUTING.md).
These rules add to it.

## Before pushing

- Run the checks for what you changed:
  - Python and tools: `ruff check .`, `mypy`,
    `python tools/check_subprocess_timeouts.py` and `pytest`.
  - Dart: analyze, `dart format --set-exit-if-changed`, and the package's tests.
  - Native, protocol or service changes: the full native CTest from the
    repository-root CMake build, then the Dart core and desktop suites with Dart
    tests pointed at the freshly built library and helper
    (`FORESIGHT_NATIVE_LIBRARY`, `FORESIGHT_HELPER`, and the separate
    `FORESIGHT_TEST_HELPER` pointing at `ForesightHelperTest`), plus the core coverage
    command (`FORESIGHT_CORE_COVERAGE_MIN=90 tools/coverage_core.sh`). See
    [native/README.md](native/README.md#verifying-native-changes).
  - Service, capture or desktop-boundary changes: also the compiled service/MCP
    suite and the desktop integration tests on an isolated display.
  - Workflow edits: actionlint with ShellCheck on PATH. actionlint silently
    skips shell checks without it. Match the hosted tool versions.
  - CI artifact, cache or release tooling: see
    [CI integrity](docs/platforms/ci-integrity.md#testing-ci-tooling-changes).
- Use a short, private, disk-backed temp root: `install -d -m 700` a directory
  under `/var/tmp` and set `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` to it. `/tmp`
  has a per-user quota, and long paths exceed the Unix socket limit. A storage
  failure is an infrastructure failure, not a pass.
- Check test counts and skip reasons, not just exit codes.
- Before a follow-up push, fetch the PR head, review threads and CI results.
  Read the failed step's output, verify each finding against current code, and
  batch the fixes.

## Reporting

- State which checks ran and which could not, such as Docker, macOS, GPU or
  real models. Never report an unexecuted path as passing on the strength of
  mocks, static reading or a narrow fixture.
- Keep failed output, including captured subprocess output.

## Do not

- Weaken, skip or delete tests, coverage gates or integrity checks to get green.
- Delete caches, clean builds or rerun successful jobs to troubleshoot an
  unrelated failure. Rerun failed jobs first.
- Present cached, stamped or older bytes as a fresh build.
- Change workflow permissions, publishing jobs or artifact-trust code without
  owner review. The rules are in [CI integrity](docs/platforms/ci-integrity.md).
- Change SDK or toolchain inputs without a one-line justification in the PR.
- Open PRs over about 100 files; split them.
