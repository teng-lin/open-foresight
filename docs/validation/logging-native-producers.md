# Native diagnostic producer checkpoint

The shared-library generation/speech failure boundary emits only a registered
native-worker failure with a constant protocol/process category. It copies no
request ID, worker message or vendor output into diagnostics. Its existing
business event remains complete and unchanged. Capture emits typed records from
its actual worker thread at start, stop, retry failure and guarded failure; a
cancelled thread reports cancellation and an exhausted retry reports failure.
These records describe observed worker state, not proof that an asynchronous
macOS capture owner or resource has retired.

`fs_set_runtime_environment` accepts canonical `FORESIGHT_LOG_LEVEL` values
`off`, `error`, `warn`, `info`, `debug` and `trace`, before the existing permanent
runtime seal. Unsupported spelling fails without changing the native level or
environment. An identical sealed replay succeeds; a changed value fails.
Logging defaults to off until effective configuration is installed. Dart must
negotiate queue ABI support before supplying this optional key, resolve an
invalid user level to canonical info before native installation, preserve the
legacy transport-only alias precedence, and keep required runtime key failures
fail-closed. That Dart configuration/adoption boundary remains integration work.

The producer fixture uses the actual production failure boundary and a real
engine handle to seal configuration without starting a model. It also starts
and joins an actual capture worker through an explicit false-executable fixture
route; it does not exercise an audio device, permission prompt or real model.
The existing fixtures that include the production C++ implementation link its
hidden diagnostic queue into their own image. This component evidence does not
replace full root native CTest, freshly matched Dart/desktop/service suites,
coverage, real macOS execution or final product acceptance.
