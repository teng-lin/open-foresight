# macOS CI timing and parallel gates

Run [39009404171](https://github.com/teng-lin/open-foresight/actions/runs/39009404171)
provides the initial measurement (before the runtime source-snapshot fix):

| Work | Observed time |
| --- | --- |
| Python tests and coverage | 14 seconds |
| Flutter installation | 39 seconds |
| Cached dependency SDK verification | under 1 second |
| Native build and CTest | about 64 seconds |
| Core analysis, coverage and service/MCP compilation | about 4 minutes |
| Desktop dependency resolution, analysis, tests and release build | about 4 minutes |
| Service integration | about 55 seconds |

That run failed early in inference runtime compilation. It does not measure a
successful cold LiteRT/Whisper build or total release packaging. Runner queue
time is separate from execution and varies with available GitHub capacity.

`FORESIGHT_PARALLEL_GATES=1` overlaps the core and desktop groups after the native
build/CTest prerequisite. macOS CI enables this within its existing runner,
without allocating additional jobs. Both gates must pass before service
integration or packaging. The core group still runs analysis, coverage, and both
AOT compilations in order. The desktop group still runs analysis, all widget
tests, and the release build in order. Default developer and Linux builds retain
the sequential path; both paths call the same gate script.

Each parallel gate writes its own log under `test-results/build-gates/`. Full
logs and exit statuses are printed in separate Actions groups after each awaited
gate finishes. Failed gates cannot be masked by a passing sibling. Interrupted
or partially launched orchestration terminates only the owned process groups
and reaps the direct children. Existing CI evidence upload retains the logs.

Potential savings are the overlap of the two groups, reduced by CPU/memory
contention. No hosted speedup is claimed until a successful comparable run.
The verified SDK and inference-runtime caches remain important: parallel tests
do not remove cold compiler work or runner queues. Splitting additional macOS
jobs can increase queue pressure and artifact-transfer overhead.

Local validation on the development Mac: native CTest 13/13; parallel core
coverage run 642 passed / 8 skipped, desktop run 107 passed / 10 skipped; both
AOT executables and the Flutter macOS release app built. The overlapping groups
completed in 83.6 seconds. Subsequent service integration passed 14 tests with
one opt-in native desktop integration skip. Offline Python validation passed
159 tests with 10 skipped and 86 subtests, including process-level concurrency,
failure propagation and partial-launch cleanup checks. These local timings do
not predict GitHub runner timing or establish a hosted speedup.
