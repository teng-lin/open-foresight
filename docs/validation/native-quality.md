# Native coverage and clang-tidy reports

Native numerical coverage (F25) and clang-tidy (F22) are **report-only**. Neither
report has a pass threshold or replaces an existing gate. Coverage percentages and
finding counts never change an exit status. The default release build is
unchanged: coverage instrumentation is applied only when
`FORESIGHT_NATIVE_COVERAGE=ON`, and these reports never add `-Werror`.

Both reports are produced by `tools/native_quality_report.py`. Run it from the
repository root as `python -m tools.native_quality_report`. Running
`python tools/native_quality_report.py` directly also still works. Exit statuses:

| Status | Meaning |
| --- | --- |
| 0 | Report written. |
| 1 | Coverage only: root CTest failed. The report is still written, with status `tests_failed`. |
| 2 | Infrastructure, metadata or tool failure, or a refused input. Nothing is reported as measured. |

## Coverage

### Configure and build (root project)

Use a separate build directory with Clang (or AppleClang). The C and C++ compilers
must be the same release. Sanitizers must be off, `BUILD_TESTING` on, and the
generator single-configuration:

```sh
cmake -S . -B build-coverage -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DFORESIGHT_NATIVE_COVERAGE=ON -DFORESIGHT_BUILD_REVISION="$(git rev-parse HEAD)"
cmake --build build-coverage
python -m tools.native_quality_report coverage \
  --build-dir build-coverage --output-dir build-coverage/native-reports/coverage-<run>
```

`cmake/ForesightNativeReports.cmake` is included last from the root
`CMakeLists.txt`. With the option enabled, it does the following:

- adds `-fprofile-instr-generate -fcoverage-mapping -femit-all-decls
  -ffunction-sections` (compile) and `-fprofile-instr-generate
  -Wl,--gc-sections` (link; `-Wl,-dead_strip` on macOS) to each target in the
  explicit `FORESIGHT_COVERAGE_TARGETS` list. It does not change the global
  flags. See "Unused inline functions" below for why the last two flags of
  each set are needed.
- enumerates every compiled target defined in the root, `native/`,
  `services/helper/` and `services/inference/` directories. Configuration
  fails if a target is neither instrumented nor excluded with a reason. It also
  fails if the root adds a subdirectory that is not classified, or if a nested
  repository directory outside `third_party/` is added. A new target therefore
  has to be classified before coverage can run.
- writes `foresight-native-reports/coverage-metadata.json` to the build directory.
  This file records the source and build directories, `FORESIGHT_BUILD_REVISION`,
  the compiler ID, version and path, CTest, the `llvm-profdata` and `llvm-cov`
  found next to the compiler (versioned names are preferred, and `xcrun` is used
  on macOS), the instrumented targets and their `$<TARGET_FILE>`, the excluded
  and absent targets, the excluded sources and the CTest working directories.
- removes that metadata file when the build directory is reconfigured with the
  option off.

### Inventory

The instrumented targets are the linked targets owned by the repository that root
CTest runs or loads. These are `foresight_native`, `ForesightHelper`,
`foresight-model`, `foresight-query`, and the test drivers and fixtures from
`native/` and `services/`. Test drivers are instrumented because they compile
production headers (for example `services/inference/*.h`). Report totals still
count only `native/`, `services/helper/` and `services/inference/`.

| Excluded | Reason |
| --- | --- |
| `foresight_protocol` | Generated protobuf/gRPC C++ in the build tree. |
| `foresight_sqlite3` | Upstream SQLite amalgamation for the Dart application runtime. |
| `model_worker_fixture`, `sqlite_commit_boundary` | Test-only child processes that write no raw profile during root CTest. See below. |
| `native_raw_query_probe` | Manual probe that no root CTest test runs. See below. |
| `third_party/` | Vendored upstream sources. |
| Build tree (`_deps`, generated headers, build identity) | Generated or fetched sources. |
| `native/*.swift` | Built by `swiftc` custom commands. Clang profile instrumentation does not apply. |
| `services/speech/` | Not added by the root `CMakeLists.txt`. Links vendored whisper.cpp. |
| `tests/` | Instrumented, but excluded from totals. |

Platform-conditional targets (macOS-only targets, `ForesightHelperTest`,
`native_test_supervisor`) are listed as `absent_targets` when a configuration
does not define them.

Every executable defines `main`. If an instrumented executable writes no raw
profile during root CTest, the merged profile holds `main` only under the
hashes of the other executables. llvm-cov then reports that executable's `main`
as `mismatched data` and drops it. This happened for the three test-only
executables above on Linux with Clang 23. `model_worker_fixture` maps no
repository source except its `tests/` driver. `sqlite_commit_boundary` maps
only its `tests/fixtures/` source. The in-scope headers that
`native_raw_query_probe` maps are also mapped through other instrumented
targets. Leaving the three executables out of the same report left the
per-file counts of every in-scope file unchanged.

### Unused inline functions

When a translation unit sees the body of an inline function (or of an unused
`static` function) but does not emit it, Clang still writes a placeholder
coverage record for it with function hash 0. If another instrumented artifact in
the same report runs that function, the merged profile holds a record with the
real hash. llvm-cov then finds the name with a different hash, reports
`N functions have mismatched data` and drops the placeholder. Small compiled
controls (Clang/LLVM 23.1.3) reproduce this with one header function that one
executable calls and another does not. Whether `NDEBUG` is defined makes no
difference. When both executables call the function, there is no mismatch,
even if their `NDEBUG` settings differ, because the merged profile keeps one
record for each hash.

The report tool treats `mismatched data` as an infrastructure failure, so the
coverage build removes the cause instead:

- `-femit-all-decls` emits and instruments every such function. Each coverage
  record then carries a real hash, and each artifact's raw profile holds a
  record (with zero counts if the function never ran) for every variant it was
  compiled with.
- `-femit-all-decls` also emits unused inline functions from SDK headers (for
  example protobuf and gRPC). Some of them reference symbols that the SDK
  shared libraries do not export, so the link fails with undefined references.
  `-ffunction-sections` together with `--gc-sections` (`-dead_strip` on macOS)
  discards that unreferenced code. The controls show that the profile counters
  and coverage records of discarded functions are kept. A function that no test
  calls is still counted as uncovered rather than disappearing from the totals.

A coverage-only `-fprofile-list` that skips instrumentation for non-repository
sources was also tested. It does not remove the mismatch for
repository-owned inline functions and does not fix the link, so it is not
used. Section GC applies only to the instrumented coverage build. Release
builds are unchanged. The macOS `-dead_strip` variant has not been qualified.

### What the report tool does

1. It refuses to run if the metadata is missing, malformed or written for a
   different build directory, or if the source revision is unknown or
   contradicts the configured one.
2. It refuses to run if the output directory exists and is not empty. Earlier
   artifacts are never reused.
3. It runs `--version` on the compiler, `llvm-profdata` and `llvm-cov`. All
   three must report the exact release (major.minor.patch) and vendor (Apple or
   upstream LLVM) that CMake recorded for the compiler. A mismatch is refused
   before any test runs.
4. It records the path, size, mtime and SHA-256 of each instrumented artifact
   (`built_by_this_tool: false`; the root build produces them).
5. It creates a fresh mode-0700 directory inside the output directory and runs
   `ctest --test-dir <build> --output-on-failure --no-tests=error` with
   `LLVM_PROFILE_FILE=<dir>/%p-%m.profraw`. All CTest output is printed and
   saved to `ctest.log`.
6. It hashes the artifacts again. If any changed during the run, it fails.
7. It merges only non-empty `.profraw` files from the fresh directory. If there
   are none, it fails. 0-byte files are listed in `profiles.empty_files`, counted
   as `empty_profile_count` in `summary.json` and not merged. The tool cannot
   detect a process that wrote no profile at all (see Limitations). It looks for
   `default.profraw` (written by a process that drops `LLVM_PROFILE_FILE`) only
   directly in the CTest working directories that CMake recorded. They are
   listed in `profiles.stray_search_directories`. A file found there is listed
   in `stray_default_profiles` with `written_during_run` and is never merged.
8. It merges with `llvm-profdata merge -sparse`. It runs `llvm-cov export
   -summary-only` to find the source files in scope. llvm-cov keeps a separate
   record for each name a file was compiled under. If one repository file
   appears under more than one name (for example
   `native/../services/inference/x.h` and `services/inference/x.h`), the run
   fails. The names are not merged (`-path-equivalence` is not used), so
   coverage is never dropped without a report. It then writes
   `coverage.json` (llvm-cov export), `coverage-report.txt` (llvm-cov report)
   and `html/` (llvm-cov show), each restricted to those sources. The filtered
   export must return exactly the discovered file names, with no file missing
   or extra, and each file's summary must equal its discovery summary.
   Otherwise the run fails. This matters because llvm-cov normalizes filter
   paths, so a recorded name containing `..` is not matched, and llvm-cov
   returns a zero-count entry with exit status 0. A nonzero exit
   status, `mismatched data`, `no coverage data found` or `failed to load
   coverage` from an LLVM tool is an infrastructure failure. These conditions
   mean the profiles and binaries do not match.
9. It recomputes totals (lines, functions, regions, branches) from the per-file
   summaries in scope. It checks the line, function, region and branch counts
   and covered counts against the totals llvm-cov reports for the same filtered
   export (`llvm_cov_totals`), and fails if any metric differs or is missing on
   one side. It then writes `summary.json`. It then writes
   `coverage-record.json`, which binds:
   - the source revision and the SHA-256 of each covered source file
   - the build directory, the metadata hash and the instrumentation flags
   - the paths, releases and SHA-256 of all tools
   - the object and profile inventories
   - the CTest command and exit status
   - the hashes of all artifacts and the argv of each LLVM command

   `modified_after_newest_object` lists covered sources whose mtime is newer
   than every instrumented object. This is a staleness hint only.

The tool hashes only the named artifacts, sources and tools. It never hashes the
whole workspace.

## clang-tidy

Configure any build with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`, then run:

```sh
python -m tools.native_quality_report clang-tidy --source-dir . --build-dir build \
  --output-dir build/native-reports/tidy-<run> --source-revision "$(git rev-parse HEAD)" \
  [--clang-tidy clang-tidy-<N>] [--config-file path] [--checks 'clang-analyzer-*'] \
  [--scope native ...] [--file native/x.cpp ...] \
  [--baseline previous/clang-tidy-record.json]
```

- **Scope:** the translation units in `compile_commands.json` that fall under
  `--scope`. The default scope is `native`, `services/helper` and
  `services/inference`. Files under `third_party/`, the build tree, Swift files
  and non-C/C++ files are excluded. Each `--file` must be a repository-relative
  in-scope entry, or the run is refused.
- **Invocation:** `clang-tidy -p <build> --quiet --warnings-as-errors=-* <file>`.
  This means findings never change clang-tidy's exit status. The configuration
  is the repository's `.clang-tidy`, if one exists, or `--config-file`.
  `--checks` is passed through as clang-tidy's `--checks` and applies on top of
  that configuration. It is recorded as `checks_argument`. The effective
  configuration for each directory is saved under `clang-tidy-config/`, and its
  hash and the checks from `clang-tidy --list-checks` are recorded.
- **Checks:** the repository has no `.clang-tidy`. clang-tidy 23 enables only
  `clang-diagnostic-*` by default, which counts as no checks, and clang-tidy
  then refuses every file. The tool detects this before analysis and fails with
  exit status 2 (`enables no checks`). It never reports such a run as zero
  findings. The recorded Linux run passes `--checks 'clang-analyzer-*'`,
  matching the analyzer checks of earlier clang-tidy defaults.
- **Classification:** each file is classified as `analyzed`, `analysis_error`
  (compiler errors or `Error while processing`, so the findings are incomplete)
  or `tool_failure` (a signal, a timeout, failure to run the tool, or a nonzero
  exit without compiler diagnostics). Only findings from analyzed files are
  aggregated. Any analysis error or tool failure gives exit status 2 and the
  record status `tool_failure`. Findings alone always give exit status 0.
- **Finding scope and deduplication:** a finding counts toward
  `summary.findings`, `summary.by_check` and the baseline only if its path is
  repository-owned and inside the run's `--scope`. That means it is not under
  `third_party/`, not in the build tree and not outside the source directory.
  Identical findings, matched on (path, line, column, check, message), are
  counted once even when several translation units report them, as happens
  with a shared header when `HeaderFilterRegex` is set. `findings[].translation_units`
  lists every unit that reported a finding. Out-of-scope findings are
  deduplicated the same way, kept in `excluded_findings` and counted in
  `summary.excluded_findings`. `raw_findings` keeps one entry per reporting
  translation unit, labelled `scope: repository` or `scope: excluded`, and its
  length is `summary.raw_findings`. `files[].finding_count` is that unit's raw count.
- **Baseline:** findings are keyed by (path, check, message) without line
  numbers and counted as a multiset. The report lists `new` and `resolved` keys
  and an `unchanged` count. Files that failed in either run are listed in
  `not_compared_files`. Any key reported by one of those files in either run is
  left out of the comparison, and the number of such keys is given in
  `not_compared_keys`. Before comparison, the baseline's findings get the same
  scope filter (using the baseline's recorded scope) and deduplication. Older
  records that counted findings once per translation unit and included
  out-of-scope paths therefore compare like for like.
  `baseline_findings` gives the recorded, out-of-scope, merged and normalized
  counts. If the clang-tidy release, the file set or the effective
  configuration differs from the baseline, the report shows `comparable: false`
  with the reasons.
- **Outputs:** `clang-tidy-record.json`, `clang-tidy-summary.txt` and
  `clang-tidy.log` (the full stdout and stderr for each file, including the
  partial output of a file that timed out). The tool has no suppression
  mechanism. Reviewed findings stay in the record, and a review rationale
  belongs with the evidence for that run.
- **Timeouts:** every tool call has a finite deadline. A crashing or failing
  `clang-tidy --list-checks` is a tool failure (exit status 2) and is reported
  as such, not as a configuration with no checks.

## Limitations

- Instrumented test runs are slower. Existing CTest timeouts (10–20 seconds for
  several native tests) may be too short under coverage. If they are, CTest
  failures appear as `tests_failed`.
- Tests that inspect exported symbols or binary contents (for example
  `native_export_barriers` and `helper_release_hooks`) may observe the profile
  runtime in instrumented binaries. These results come from the coverage build
  and do not describe the release configuration.
- A process that drops `LLVM_PROFILE_FILE` writes `default.profraw` in its own
  working directory. That file is reported only if the working directory is one
  of the recorded CTest working directories. It is never merged, so coverage for
  that code is understated, whether or not the file was found.
- With `%p-%m`, the profile runtime creates no file when a process starts
  (online merging skips the startup truncation). A process that ends through `_exit`, a signal or `abort` therefore
  leaves **no file**, and the tool cannot detect it. Its coverage is lost
  without a trace, which understates coverage and never inflates it. A compiled
  control with Clang 23.1.3 confirmed this for `_exit`, SIGKILL, `abort` and a
  forked child's `_exit` (with `%p` alone, the same cases leave 0-byte files).
  The only indirect signal is the infrastructure failure llvm-cov raises when an
  instrumented executable wrote no profile anywhere: its `main` is then reported
  as `mismatched data`. An executable whose other runs did flush is not flagged.
  A 0-byte file can still occur when a process stops after the runtime opened
  its file but before it wrote data. Such files are listed in
  `profiles.empty_files` and not merged. At least one non-empty profile is
  required, and malformed non-empty profiles and LLVM tool failures remain
  infrastructure failures.
- `%m` enables online profile merging within a process's per-module files. The
  directory is fresh for each run, so no earlier data can be merged in.
- If root CTest times out, only CTest itself is terminated, and its partial
  output is kept in `ctest.log`. Test processes it started may need manual
  cleanup. An LLVM tool that times out is logged in `llvm-tools.log` with its
  partial stderr, and the run fails.
- New compiled targets in owned directories must be explicitly classified.
  The current upstream SQLite target is excluded from repository-owned totals.
