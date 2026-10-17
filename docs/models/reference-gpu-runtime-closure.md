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
arm64 Clang translation units. The builder applies it on macOS and records its
hash separately from the common source patch.

## Linux x86_64 accelerator STL and callback ABI

On Linux x86_64, `foresight-model --model .../gemma-4-E4B-it.litertlm --probe`
crashed with `SIGSEGV` at `libLiteRtWebGpuAccelerator.so + 0x661bb7` reading
`0x100004600` during `ModifyGraphWithDelegate`. All prebuilt vendor binaries in
`prebuilt/linux_x86_64/` were compiled by Clang against `libc++` (`std::__1`) with
`ABSL_ATTRIBUTE_TRIVIAL_ABI` (`[[clang::trivial_abi]]`) enabled on `absl::Status`,
while the source-built `liblitert-lm.so` previously defaulted to GNU `libstdc++`
(`std::__cxx11`) and non-trivial `absl::Status`:

- `libLiteRtWebGpuAccelerator.so + 0x186f2e..0x186f39` casts `TfLiteContext::impl_`
  to `tflite::Subgraph*` and reads two `std::unordered_map` fields at `libc++`
  offsets `+0x2d0` and `+0x2f8` (`sizeof(std::string) == 24`,
  `sizeof(std::map) == 24`, `sizeof(std::unordered_map) == 40`). Under `libstdc++`
  (`32`, `48`, `56` bytes), `Subgraph` shifts those maps to `+0x308` and `+0x340`,
  leaving two 32-bit integers (`0x100000000`) at `+0x2f8` and faulting at
  `+0x661bb7` (`0x100004600`).
- `libLiteRtWebGpuAccelerator.so` also invokes
  `LiteRtWeightLoader::PrepareAccessForBuffer` (`liblitert-lm.so + 0x109b690`)
  with `this` in `%rdi`, `buffer_id` in `%esi`, and expects `absl::Status` in
  `%rax`, whereas an unpatched Abseil build expects a hidden `sret` pointer in
  `%rdi` and treats `%rsi` (`buffer_id`) as `this`.

Linux x86_64 source builds now apply `linux-trivial-abi.patch`, compile with
Clang against `libc++` headers, and statically link PIC `libc++.a` and
`libc++abi.a` with `--exclude-libs,libc++.a:libc++abi.a`. Both the builder and
release verifier reject dynamic `libstdc++.so` or `libc++.so` linkage and require
`linux_abi_patch_sha256` plus a passing `native_status_abi_report`.

`test_litert_status_abi.py` compiles an actual-header callee DSO and an independent
vendor-convention caller checking both `SubgraphLayout` (`std::string`,
`std::map`, `std::unordered_map` offsets) and virtual `absl::Status` register
returns. It reproduces `SIGSEGV` (-11) when the callee uses `libstdc++` or
unpatched Abseil headers, and passes (`vendor_register_return_callback_ok`) when
compiled with `libc++` and the platform trivial-ABI patch. Packaged provenance
retains the vendor hashes and the platform ABI patch/report hashes.
