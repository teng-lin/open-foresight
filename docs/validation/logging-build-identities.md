# Diagnostic input identity generator

This is the generator/input-contract checkpoint. It does not wire CMake,
packages, runtime consumers or artifact trust. Native owner `09e88036` is a
frozen development dependency, not native-unit or installed acceptance.

`tools/diagnostic_build_inputs.json` classifies the twelve current diagnostic
C/header sources, selected platform, compiler family and platform floor. Native
inventory discovery rejects a newly omitted C/header/C++ input in the owned
`diagnostic_` source family. Other native application targets are not worker
inputs; future build wiring must bind its actual target sources to this contract.
Quoted project includes must stay in the selected inventory; unsupported
preprocessing fails closed. Toolchain headers and compiler bytes belong to the
explicit pinned toolchain fingerprint. The command accepts an ordered reviewed
flag vector; arbitrary defines, flags and environment options are rejected.

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

Default `worker --native-id <64hex> --mode aot` refuses while any required root
is absent, before reading closure content. Even stub files cannot promote this
pending contract into a reviewed production worker identity. Worker hashing is
currently available only to explicitly marked synthetic fixture contracts, with
`kind: fixture-worker`; there is no production-worker-ID claim.

The pending allowlist is limited to owned diagnostics, the standalone entrypoint,
its scoped-FD utility, native support and the core dependency declarations. It
excludes the application/service import graph. Each runtime file must be included
or have a reasoned explicit exception. Dart import/export/part headers, including
conditional imports, must resolve within that positive inventory or a closed
SDK/package URI allowlist. Unsupported header grammar fails closed. Encountering
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
