# Contributing

Open an issue for a substantial behavior change, then use a branch and a focused
pull request. Include the problem, resulting behavior, and checks you ran. Link
and close the relevant issue. Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Build and test

The supported targets are Linux x86-64 and Apple Silicon macOS 15+. Install the
native toolchain and pinned Flutter version described in [README.md](README.md#build-from-source)
and the [macOS guide](docs/platforms/macos-support.md). Python 3.13 is the supported build/test tooling version.
Install its checked-in, hash-pinned development dependencies:

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r requirements-dev.lock
```

Run the offline tooling suite with `.venv/bin/python -m pytest`. For the core
Dart package, run:

```sh
(cd packages/foresight_core && dart pub get --enforce-lockfile && dart analyze && dart test)
(cd apps/desktop && flutter pub get --enforce-lockfile && flutter analyze && flutter test)
```

`tools/build.sh` is the complete Linux entry point. On macOS use
`tools/build.sh --platform macos` with the SDK options in the platform guide.
It builds native targets, runs CTest and Dart/Flutter checks, compiles service/MCP,
and builds the desktop application. `FORESIGHT_BUILD_DIR`, `FORESIGHT_PYTHON`, and
`FORESIGHT_BUILD_JOBS` configure output, Python, and parallelism. Run
`ctest --test-dir build --output-on-failure` to repeat native checks after a build.
For `tools/build_linux_container.sh`, select an isolated Python 3.13 installation
with `FORESIGHT_HOST_PYTHON`. The driver mounts that installation read-only and
creates a private, hash-locked tooling environment at the same absolute path in
the separate build and test containers. System and home-directory prefixes are
rejected; the existing SDK Python environments are not replaced.
`tools/coverage.sh` and `tools/coverage_core.sh` collect Python and core coverage.
Python enforces 95% combined line/branch coverage, including Python subprocesses
and the native model setup tool. The Python gate distributes whole test files
across at most four available CPUs locally and two in CI, combines worker and
subprocess coverage, and fails worker crashes without restarting them.
`FORESIGHT_PYTEST_WORKERS` can select a smaller positive worker count; ordinary
pytest arguments such as `--basetemp` still pass through `tools/coverage.sh`. See the
[whole-file scheduler](https://pytest-xdist.readthedocs.io/en/stable/distribution.html)
and [combined worker coverage](https://pytest-cov.readthedocs.io/en/stable/xdist.html)
contracts. Linux core and desktop gates enforce 90% line
coverage; macOS coverage is report-only and is not collected on ordinary PR runs.
Keep compiler, package-manager, signing, and model-runtime boundaries offline in
Python unit tests, and retain real byte-level archive, receipt, checksum, and
provenance assertions. Dedicated platform acceptance verifies the actual external
tools. Lower coverage gates only with a reviewed explanation.

### Acceptance evidence fixture

The original CI failure evidence archive is not read from the source tree.
`tests/fixtures/ci-acceptance-failures-20261020.json` (with its `.sha256`) pins
its name and SHA-256, and `tools/evidence_fixture.py` pins the commit whose raw
GitHub URL serves those bytes. Provision it once before running the full Python
suite or its historical acceptance-evidence tests:

```sh
.venv/bin/python -m tools.evidence_fixture --fetch            # network, opt-in
.venv/bin/python -m tools.evidence_fixture --archive PATH     # verified local copy
.venv/bin/python -m tools.evidence_fixture --check            # verify only
```

The asset is cached at `$FORESIGHT_EVIDENCE_CACHE`, or
`${XDG_CACHE_HOME:-~/.cache}/open-foresight/evidence` when that is unset (macOS
included). The cache directory must not be a symlink or group/world-writable.
Bytes are published atomically only after SHA-256 verification; symlinked,
partial, or tampered assets are rejected. The offline tests never fetch or call
Git; a missing asset fails with the provisioning command instead
of skipping. For a Git-free source export or an offline Mac, copy the archive
from a machine that has it (or download the pinned URL shown in the
missing-asset error) and run `--archive PATH`, or point
`FORESIGHT_EVIDENCE_CACHE` at an already provisioned cache. The selected platform
contracts do not consume this archive and do not require it.

Read [integration gates](docs/testing.md) for real model,
virtual audio, service, and installed-package acceptance. A skipped test is not
acceptance evidence. Never use or upload personal profiles, cloud credentials,
meeting audio, or reference model assets in a pull request. Restricted fixtures
require independently authorized local inputs.

## Review and maintenance

Update `CHANGELOG.md` `[Unreleased]` for user-visible changes.

The offline Python suite discovers `tests/` automatically. Build/device suites in
`tests/integration` and `tests/service` run explicitly; every excluded module and
its reason is recorded in `pytest-exclusions.json`. A discovery guard rejects new
uncollected test modules.

Keep generated bindings, lockfiles, package notices, and user documentation in
sync with behavior changes. Schema changes need an ordered Store migration and
rollback/upgrade coverage. Add regression tests for behavior changes and record
platform limitations honestly. CI and review findings must be resolved before
merge. Do not publish installers from an unreviewed branch; releases use the
exact-commit draft and acceptance workflow described in the README.

## Quality checks

Before every push, run the shared guards, including metadata that crosses language
boundaries:

```sh
.venv/bin/python -m tools.check_local_validation
```

The command runs skip-inventory, documentation, lint/type, subprocess-timeout and
workflow checks, retains each raw log in a private canonical directory under
`/var/tmp`, and reports every failed guard. It requires the hosted actionlint
1.7.7 and ShellCheck 0.9.0 on PATH. Add `--full-python` to run the unchanged Python
coverage gate after the shared guards pass. This command supplements the native,
Dart, service and platform acceptance commands above; it does not certify
unexecuted platforms. Evidence paths are printed and remain available on failure.

CI runs `ruff check .`, `mypy`, and `python tools/check_subprocess_timeouts.py`.
Install the pinned development requirements first. Mypy checks every production
Python script, including unannotated function bodies; tests with dynamic native
API doubles are covered by ruff and the runtime suites.

Format all tracked Dart sources with Flutter 3.35.7's Dart formatter and C/C++
sources with clang-format 22.1.8 (configuration in `.clang-format`). CI rejects
format differences across all tracked project sources, including fixtures; vendored C/C++ under
`third_party` remains upstream-owned. Generated
files should be formatted after regeneration.

Synchronous Python subprocesses must pass an explicit finite `timeout` in seconds.
Quick commands and probes generally allow 300 seconds; dependency builds allow
3600 seconds. Long-lived `Popen` protocols use operation deadlines and bounded
shutdown waits. Callers of build wrappers may override their bounded default.


Python locks are resolved for Python 3.13. When requirement inputs change, use:

```sh
uv pip compile --python-version 3.13 --generate-hashes requirements-dev.txt --output-file requirements-dev.lock
uv pip compile --python-version 3.13 --generate-hashes requirements-format.txt --output-file requirements-format.lock
uv pip compile --python-version 3.13 --generate-hashes requirements-litert.txt --output-file requirements-litert.lock
```

The protobuf runtime and `types-protobuf` stubs use the same major version. The
Dart protobuf compiler is resolved separately with
`(cd tools/protoc_plugin && dart pub get --enforce-lockfile)`; put its `bin`
directory on PATH before running `tools/check_dart_bindings.py`.

Dart tests allocate disposable directories with `createTestTempDirectorySync`
or `createTestTempDirectory` from
`package:foresight_test_support/test_paths.dart`. Both honor
`FORESIGHT_TEST_TEMP_ROOT` and register cleanup with `addTearDown`. Register
resource cleanup after allocating its directory, using `addTearDown`, so database
and process owners close before their files are removed. For fixtures allocated
in `setUp` or `setUpAll`, register their resource cleanup in that same setup scope
(or a later setup callback).

The recording ABI fixtures need a C++17 compiler (`c++`) on PATH. The shared
`buildCachedNativeFixture` helper builds each source/compiler/platform identity
once in `$FORESIGHT_TEST_TEMP_ROOT/foresight-native-fixtures` (the system temp
root when unset), then copies it to a unique test path to isolate native globals.
This disposable build cache can be removed when no suite is running; no separate
CMake setup is needed for the Dart suites.
