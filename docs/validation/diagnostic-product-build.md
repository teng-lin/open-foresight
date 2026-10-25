# Diagnostic product build candidate

`cmake/ForesightDiagnostics.cmake` builds the independent system-only diagnostic
support library and launcher. It shares no application-native, model, audio,
SQLite or Dart link dependency. The native identity generator inventories every
owned diagnostic C/H source before creating an ID; its generated outputs remain
outside that source hash. Native identity remains independent of worker identity.

The reviewed compiler profiles now include the actual qualified Ubuntu GNU
13.3.0 compiler as well as Clang, and AppleClang on macOS. This records the
selected compiler; it changes neither the compiler nor SDK version. CMake passes
its selected compiler family/version, actual compiler SHA, public system metadata
fingerprint and actual closed compile options to the generator. Unknown compile
or additional link options, unsupported targets, missing metadata and mismatched
expected fingerprints refuse diagnostic products. Configure writes an unavailable
state before selection, so a failed reconfigure cannot advertise stale artifacts
as current. Existing artifacts are retained. Product packaging must check that
state and the final reviewed worker identity; it must not infer availability from
an old library's existence.

`tools/diagnostic_toolchain_metadata.py` fingerprints a closed set of public
metadata. This is explicitly **not whole SDK byte attestation**. Linux records the
selected compiler bytes/version plus exact selected `libc6`, `libc6-dev`,
`linux-libc-dev`, `libc-bin`, `binutils` and `binutils-x86-64-linux-gnu` package
versions. macOS records the actual selected compiler and invocation shim bytes,
selected OS SDK version/build and `SDKSettings.json` SHA. An explicit CMake SDK
root must resolve to that same selected OS SDK. Apple CMake's build-version suffix
is checked against four closed numeric compiler macros when absent from the
banner; unrelated macros and the full environment/define vector are not stored.
The application dependency SDK manifest is not an OS SDK receipt and is unused.

Actual read-only probes of the existing qualified toolchains observed GNU
13.3.0 on the c77 Ubuntu image and AppleClang 21.0.0.21000334 with SDK27.0 build
26A425 on HanSolo. These are public metadata observations, not fresh application
builds or an endorsement of pending diagnostic products.

The focused Python batch runs 122 tests with no skips, including deterministic
identity changes, invalid compiler-family combinations, exact metadata inventory,
closed CLI errors, actual standalone CMake compilation and unavailable-state
refusal after reconfiguration without deleting old bytes. The standalone CMake
fixture supplies deliberately synthetic public metadata to isolate build wiring;
it is not toolchain attestation or installed-product acceptance. Actual product
qualification, whole Python checks, Darwin CMake selection, owner review of final
artifact/package consumers and full application matrices remain pending.

Worker generation remains `pending` and refuses by default. No production worker
ID, reviewed closure flag, source verifier or package acceptance is introduced
here. The subsequent startup and packaging integration must preserve that refusal
until the complete real runtime closure and selected SDK have been reviewed.

The candidate native-runtime allowlists add only the two platform variants of
SQL/diagnostic support, the diagnostic launcher and three public native identity/
availability records. Real archive/unpack/repack and run-stage consumer tests
verify all added bytes while continuing to exclude compiler/dependency trees.
This path inventory change needs final owner review. Artifact producer selection,
receipts, checksums, source identity, permissions and publication rules are
unchanged. It does not authorize using an unreviewed worker or stale products.
