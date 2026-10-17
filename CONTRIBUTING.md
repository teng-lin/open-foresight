# Contributing

Open an issue for a substantial behavior change, then use a branch and a focused
pull request. Include the problem, resulting behavior, and checks you ran. Link
and close the relevant issue. Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Build and test

The supported targets are Linux x86-64 and Apple Silicon macOS 15+. Install the
native toolchain and pinned Flutter version described in [README.md](README.md#build-from-source)
and the [macOS guide](docs/platforms/macos-support.md). Python is build/test tooling.
Install its checked-in, hash-pinned development dependencies:

```sh
python3 -m venv .venv
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
`tools/coverage.sh` and `tools/coverage_core.sh` collect Python and core coverage.

Read [integration gates](docs/validation/integration-gates.md) for real model,
virtual audio, service, and installed-package acceptance. A skipped test is not
acceptance evidence. Never use or upload personal profiles, cloud credentials,
meeting audio, or reference model assets in a pull request. Restricted fixtures
require independently authorized local inputs.

## Review and maintenance

Keep generated bindings, lockfiles, package notices, and user documentation in
sync with behavior changes. Schema changes need an ordered Store migration and
rollback/upgrade coverage. Add regression tests for behavior changes and record
platform limitations honestly. CI and review findings must be resolved before
merge. Do not publish installers from an unreviewed branch; releases use the
exact-commit draft and acceptance workflow described in the README.
