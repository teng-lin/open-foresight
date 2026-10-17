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
