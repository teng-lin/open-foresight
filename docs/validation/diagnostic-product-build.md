# Diagnostic product build candidate

`cmake/ForesightDiagnostics.cmake` builds the independent system-only diagnostic
support library and launcher. It shares no application-native, model, audio,
SQLite or Dart link dependency. The native identity generator inventories every
owned diagnostic C/H source before creating an ID; its generated outputs remain
outside that source hash. Native identity remains independent of worker identity.

The compiler family profiles include GNU as well as Clang, and AppleClang on
macOS. They record the selected version; the actual qualified Ubuntu build uses
GNU 13.3.0. These values identify the selected compiler without changing
the compiler or SDK version. CMake passes
its selected compiler family/version, actual compiler SHA, public system metadata
fingerprint and actual closed compile options to the generator. Unknown compile
or additional link options, unsupported targets, missing metadata and mismatched
expected fingerprints refuse diagnostic products. Configure writes an unavailable
state before selection and at the start of every product build. Configure alone
never advertises available products. Only `foresight_diagnostic_products`, after
both links and exact embedded NativeID marker checks succeed, publishes available
state. A compile/link failure leaves old artifacts unavailable. Existing artifacts
are retained. Product packaging must check that
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
13.3.0 on the c77 Ubuntu image and AppleClang 21.0.0.21000334 with SDK 27.0 build
26A425 on HanSolo. These are public metadata observations, not fresh application
builds or an endorsement of pending diagnostic products.

The focused build and identity Python batch includes deterministic
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


Diagnostic compilation runs in the fixed, product-only
`cmake/DiagnosticProducts` sub-build. Parent targets are scheduling handles; no
application target/source usage requirements or compiler-rule templates reach
that build. The producer passes only selected compiler, build type, public OS
context, closed flags, output location and NativeID. Configure, build and public metadata probes run with the same allowlisted
environment: `/usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C` and a private
`TMPDIR`. No ambient make, compiler launcher, driver-override or linker variables
reach them. A fresh private sub-build configuration
prevents previously cached hooks or compiler wrappers from persisting. This
optional producer requires CMake 3.24 for `--fresh`; repository toolchain inputs
are unchanged. The fixed Unix Makefiles generator and existing `/usr/bin/make`
keep parent generator/rule inputs outside this optional producer; missing make
leaves diagnostics unavailable. The two small diagnostic products are actually rebuilt on each
product invocation, independently of heavyweight application native targets.

The current standalone CMake fixture has 49 controls, including configure-only
unavailability, compile-failure state, omitted source/Threads-source refusal,
late build-type refusal, byte equality under seven parent-rule changes, the
export initializer, an injected inner-cache hook, hostile build environments,
SQL output-directory/availability cases and umask-002 normalization. Linux GNU
executes 48 and skips the Clang-only driver case; Darwin executes 48 and skips
the GNU-ld-only `LD_RUN_PATH` case.
Partial link failure may leave a newly linked launcher beside the old failed
library; availability remains false until both matching products are verified.
This is a build-unit regression result, not whole native/application acceptance.

When SQL support is present, `foresight_runtime_support_products` depends on both
finished diagnostic products and SQL support before publishing their byte receipt.
The receipt verifier also requires each diagnostic product's exact embedded ID
marker. Receipt mechanics and real compilation remain separately reported evidence.

Native identity algorithm v2 also hashes the six explicit CMake producer scripts.
This makes a producer-recipe edit change NativeID while keeping Dart/WorkerID
and SQL implementation bytes outside its inputs. The private marker format stays
v1 and adds no exported ABI. Generated identity values remain outside all source
inputs, so no generated ID is hashed into itself. The old configure-time cache
availability flag stays false; only the verified product-state file is current.

Runtime receipt creation waits for SQL's deferred identity decision. Optional
unavailable SQL identity leaves mandatory SQL compilation available and omits
the combined receipt; required identity refuses. The receipt producer compares
the actual SQL target location to the expected product path before normalizing
or hashing it, so a stale file left by an output-directory override cannot be
published as the fresh SQL target. Captured producer failures are retained in
build-local error logs. Consumers always recompute `--verify`.
