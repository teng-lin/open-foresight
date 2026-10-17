# Packaged GPU runtime dependencies

The actual packaged macOS GPU embedding probe failed before inference because no
GPU accelerator registered. The pinned upstream wheel's common prebuilt list
omitted `libwebgpu_dawn`, required by the WebGPU accelerator on both Linux and
macOS. Its macOS list also omitted the native Metal accelerator and sampler.
These are materialized Git LFS artifacts in the pinned LiteRT-LM source checkout.

The canonical source patch now includes Dawn in the common wheel payload and
adds the Metal accelerator/sampler only on macOS. The standalone builder checks
the complete platform payload before publishing a manifest and records each
vendor library's hash. The release verifier requires all five Linux or seven
macOS dependencies, rejects empty files/LFS pointers and checks their hashes
against the wheel. Linux packaging also copies Dawn from that verified wheel.

The macOS C API links with `LC_RPATH=@loader_path`, allowing bare-name native
plugin discovery from the owned SDK directory without a checkout working
directory or `DYLD_*` variables. During package relocation, a colocated plugin
dependency may be resolved and rewritten to an explicit loader-relative load.
The final audit uses actual load commands/rpaths, without relocation guesses.
An expanded system-directory candidate must exist on disk or in dyld's shared
cache. This preserves cache-only Swift libraries and rejects an invented
`/usr/lib/swift/libwebgpu_dawn.dylib`.

Validation includes 17 manifest/overlay tests, three builder closure tests, two
source snapshot tests and five actual macOS Mach-O tests. The latter include a
bare-name plugin with a transitive dependency, relocated into a path with spaces
and run from `/` with only a minimal PATH. These checks establish the dependency
and relocation rules; fresh SDK wheel, sealed package and production GPU model
runs remain required to establish GPU acceptance.

## macOS accelerator callback ABI

After the dependency closure was corrected, actual GPU embedding reached the
Apple M4 WebGPU/Metal adapter and then crashed in
`LiteRtWeightLoader::PrepareAccessForBuffer`. The matching worker crash showed a
write into that function's read-only code. Its source-built callee saved X8 as a
hidden Status return pointer; the vendor accelerator instead left its virtual
function address in X8 and expected the returned Status in X0. The vendor caller
at offset `0x43103c` and callee store at `0x811ed0` explain the SIGBUS directly.
This is a C++ return-ABI mismatch rather than a missing accelerator or model error.

Pinned open-source Abseil unconditionally disables `ABSL_ATTRIBUTE_TRIVIAL_ABI`,
while the prebuilt macOS accelerator uses Clang's trivial ABI for Status. A
separate `macos-trivial-abi.patch` enables that attribute consistently for Apple
arm64 Clang translation units. The builder applies it only on macOS and records
its hash separately from the common source patch. Linux source and Abseil headers
remain unchanged; Linux GPU ABI equivalence is not asserted.

`test_litert_status_abi.py` compiles an actual-header callee DSO and an independent
vendor-convention caller. With the original pinned headers it reproduces SIGBUS
(-10); the exact new patch applied to a private copy of those headers passes.
No GPU or model is loaded by this focused check. macOS source builds must pass
that check against their resolved Abseil repository, and the release verifier
requires the pinned patch hash plus the checksum-verified passing ABI report.
Actual production GPU embedding must still be rerun after the coherent rebuild.
The platform snapshot/provenance checks pass four source-snapshot tests, twenty
artifact tests and the three existing vendor-closure tests. Packaged provenance
retains the vendor hashes and the macOS ABI patch/report hashes.
