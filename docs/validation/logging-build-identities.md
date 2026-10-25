# Diagnostic input identity generator

This is the generator/input-contract checkpoint. It does not wire CMake,
packages, runtime consumers or artifact trust. Native owner `09e88036` is a
frozen development dependency, not native-unit or installed acceptance.

`tools/diagnostic_build_inputs.json` classifies the fourteen current diagnostic
C/header sources, selected platform, compiler family and platform floor. Native
inventory discovery rejects a newly omitted C/header/C++ input in the owned
`diagnostic_` source family. Other native application targets are not worker
inputs; future build wiring must bind its actual target sources to this contract.
Quoted project includes must stay in the selected inventory; unsupported
preprocessing fails closed. Native directives use a closed allowlist;
`include_next`, `import` and `embed` are refused. Angle includes must name one of
the exact current SDK headers in `SYSTEM_HEADERS`, never an arbitrary project
header. Their resolution, include search order, toolchain headers and compiler
bytes must bind to the explicit verified toolchain fingerprint at integration.
The command accepts an ordered reviewed flag vector; arbitrary defines, flags
and environment options are rejected.

Both dependency scanners normalize CR, LF and CRLF before recognizing line ends.
The C scanner accepts exact backslash/newline splices, refuses whitespace-splice
extensions and line-crossing/unclosed literals, including unsupported quoting in
preprocessor messages. It is not a general C/assembler compiler: inline assembly
file embedding is outside this checkpoint's scanner proof and absent from the
current owned inputs. Build owners must classify any future embedding mechanism
and actual target sources before it becomes an identity-qualified product.

For example, after the build owner has verified its actual public compiler and
SDK artifact digests:

```sh
python -m tools.diagnostic_build_identity native \
  --target linux-x86_64 --compiler-family clang --compiler-version 22.1.8 \
  --compiler-sha256 "$compiler_digest" --toolchain-sha256 "$sdk_digest" \
  --flag=-std=c11 --flag=-O2 --format header \
  > build/generated/diagnostic_native_id.h
```

The compiler version/digests above are supplied build metadata. The generator
neither discovers a compiler from PATH nor proves that CMake used that compiler.
The eventual integration must bind the verified actual compiler, toolchain and
complete compile recipe to these fields. Linux's selected floor is glibc 2.39;
Darwin's is macOS 15.0/arm64 and requires the corresponding reviewed minimum-OS
flag. Unsupported recipes require a reviewed contract update, not an ambient
option. Both products will embed the same selected native identity at that
integration; there are no native products from this generator alone.

For production components, algorithm v2 additionally hashes the six explicit
CMake producer scripts, including the fixed isolated product project. Fixture
contracts retain their scoped synthetic input inventory. Producer hashes contain
no generated identity values or Dart/WorkerID inputs.

The default JSON result records `kind: native-components`, a 64-character
lowercase `native_id`, and its canonical nonsecret input record. `--format header`
emits only the native macro. Keep generated output outside the source inventory;
the generated identity is never itself an input. `--expected-id <64hex>` always
recomputes and compares actual classified source bytes. No Git metadata, absolute
source-root spelling, timestamps, personal content or arbitrary environment is
hashed. Native IDs do not depend on Dart source or the worker ID. Tool/config
changes remain existing build-tool cache inputs; this checkpoint changes no
legacy cache selector, receipt, permission or trust rule.

## Worker closure remains unavailable

The confirmed future roots are:

- `native/diagnostic_support.c` and `.h`;
- `packages/foresight_core/lib/src/diagnostics/storage_worker.dart`,
  `storage_worker_native.dart`, `storage_worker_protocol.dart`, and
  `storage_worker_dispatch.dart`;
- `packages/foresight_core/bin/diagnostic_storage_worker.dart`.

The pending diagnostics inventory also includes the confirmed shared
`bounded_json.dart` codec. Its declaration does not certify a complete worker.

Default `worker --native-id <64hex> --mode aot` refuses while any required root
is absent, before reading closure content. Even stub files cannot promote this
pending contract into a reviewed production worker identity. Worker hashing is
currently available only to explicitly marked synthetic fixture contracts, with
`kind: fixture-worker`; there is no production-worker-ID claim.

The pending allowlist is limited to owned diagnostics, the standalone entrypoint,
its scoped-FD utility, native support and the core dependency declarations. It
excludes the application/service import graph. Each runtime file must be included
or have a reasoned explicit exception. Supported Dart import/export/part headers,
including conditional imports, must resolve within that positive inventory or a
closed SDK/package URI allowlist. Unsupported header grammar fails closed;
annotations and unsupported conditional-string spellings can therefore require
a reviewed scanner change before real worker closure activation. Encountering
an unlisted application path or a reference-distribution, credential or
search-service path refuses it before opening the target. The generator does
not inspect SearchService to guess a narrower value-supply exclusion.

Fixture worker records bind their complete classified source bytes, generated
location/operation catalog hash, pinned Dart/Flutter versions and revision,
explicit verified compiler/toolchain fingerprints, record schema, worker mode
and expected native ID. Supported worker modes are `jit`, `kernel`, and `aot`;
a parent's Flutter mode does not select its child's mode. Unknown SDK/options,
full `-D` vectors, duplicate/out-of-root inputs, links and changed-during-read
files are refused. There is no credential-config, distribution-tool/test,
arbitrary environment or binary-self-hash input.

Actual worker source implementation, runtime SDK/dependency verification,
per-target build/compile definitions, source/compiled dispatch evidence and all
consumer/package/cache wiring remain separate work. Owner review of that wiring
is still required at final integration; a deterministic fixture identity does
not satisfy it.


The subsequent diagnostic product build candidate binds the native generator to
actual CMake recipes and selected public compiler/OS metadata; see
[the build candidate](diagnostic-product-build.md). Its review and qualification
are separate from this original generator-only checkpoint. Worker generation
remains pending until the real closure and selected SDK byte inventory converge.

## Standalone source context

`diagnostic_worker_context.py` separately emits the `standalone-worker` JIT
context from the complete flat diagnostics inventory, its standalone entry, the
scoped-FD utility, native support declaration and core dependency declarations.
It refuses application, search-service and credential paths before opening any
declared runtime input. Selected dependencies are exactly ffi, meta, path, crypto,
typed_data and collection from public hosted/pub.dev roots. The collector binds
all their library bytes and validates every declared import target. Core uses its
actual language version 3.8 with the pinned Dart 3.9.2 VM. The scanner consumes balanced annotation arguments with string/comment handling,
then checks the following directive, including annotated imports and exports.
Unsupported generic annotations and interpolated metadata strings refuse.

The record binds all SDK bin/lib bytes. The child rechecks the actual VM,
kernel-service snapshot and complete SDK lib inventory needed by its JIT mode.
Its selected public source/package roots are descriptor-walked without symlinks;
files require stable regular-file metadata, one link, approved ownership and no
group/other write permission. Manifest paths are classified before source or
package content reads. The manifest itself must be canonical JSON and match
compiled NativeID, WorkerID, CatalogID and SDK identity.

Only the exec child performs runtime hashing: it first arms its native owner,
receives the independent watch acknowledgement and maps its inherited pages.
It then looks up the three optional streaming SHA functions in the original
support image; the existing fourteen owner addresses remain unchanged. HELLO
and INIT follow verification, under the unchanged one-second native bootstrap
deadline. Scalar SHA is system-only; the unqualified CommonCrypto opt-in is
explicitly disabled.

The legacy generic worker generator remains pending. Kernel/AOT contexts from
the new collector retain candidate status until compilation/byte receipts and
the standalone installed companion are wired and qualified. This JIT checkpoint
does not claim those paths, package adoption or complete application acceptance.

## Compiled standalone companion

`build_diagnostic_worker.py` builds JIT, kernel or AOT contexts. Kernel/AOT
compilation uses a private snapshot of the sealed owned sources and six public
packages, with a generated resolver containing only those packages and core.
The selected SDK is fingerprinted before and after compilation. Compiler
subprocesses receive a fixed environment and a 300-second deadline; failed
output is retained. Previous availability and the worker byte receipt are
invalidated before a new build begins.

The worker record additionally binds the three exact producer Python files and
the fixed public compilation recipe. It admits the two definition-only
async/FFI modules `native_diagnostics.dart` and `native_lifetime.dart`; no
application image is loaded by their import. The current inventory requires the
repaired native adapter's `native_queue_adapter.dart` part and exact session
bytes; the pre-adapter worktree cannot manufacture that missing closure.

A successful build publishes `native/diagnostic-worker-inputs.json` and
`application/diagnostic-worker-build.json`. The latter binds the fixed artifact
path, mode, size and SHA-256, IDs and complete public Dart definitions.
`verify_worker_build(root, build, sdk, config, mode)` recomputes all inputs and
artifact bytes. The matching CLI `--verify --defines-output PATH` emits a sorted
NUL-separated vector of exact `-Dkey=value` arguments only after verification.
Service/MCP compilation consumes that vector without rebuilding or guessing IDs.

AOT selects the standalone `foresight-diagnostic-worker` companion. Source
contexts use `build/application`; installed Linux uses `bin`, and installed
macOS uses `Contents/Resources/bin`. Recognized installed executable locations
ignore the compiled source-fixture authority and use package-relative support
paths. Installed-copy execution and final package-byte sealing require their
own qualification; source execution alone does not establish that acceptance.
