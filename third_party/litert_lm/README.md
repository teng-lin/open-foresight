Public C API headers and model-header schema from Google LiteRT-LM v0.18.0,
commit b2f686e2ed4718fb84ec398a61dd59ca0f0aff27.
https://github.com/google-ai-edge/LiteRT-LM/tree/v0.18.0
Licensed under Apache-2.0; see LICENSE and individual files.
No Google Foresight private ABI is used.

`c/foresight_extensions.h` is an Open Foresight extension, not an upstream
0.18.0 API. `tools/build_litert_extensions.py` at the repository root applies the
patches below to that exact upstream source. The published stock libraries do not
export the extension.

## Native stop-token sequences

The original Foresight bridge appends each nonempty `stop_token_ids` integer
sequence to `SessionConfig::GetMutableStopTokenIds()` before creating a
conversation. The public 0.18.0 C API and Python wrapper do not expose that
operation, and matching a decoded text substring is not equivalent.

`stop-token-sequences.patch` adds a C entry point that copies each sequence into
the real `SessionConfig` through the upstream C++ accessor. Empty sequences are
ignored; order and duplicates are retained. The Python wrapper applies the setter
before the conversation config copies the session config.

The shared native generation worker accepts optional `stop_token_ids` in its
conversation JSON on Linux and macOS and advertises `native_stop_token_sequences`
in `--probe` metadata. Requests with nonempty sequences fail explicitly on the
stock library; ordinary conversations keep working with it. Custom stops disable
empty-history base reuse. Notes also request `use_default_output_limit: true` for
plain conversations, preserving the original native output default; tool
conversations reject this flag.

## Packaged GPU dependencies

The upstream wheel's prebuilt lists omit `libwebgpu_dawn`, which the WebGPU
accelerator needs on Linux and macOS, and on macOS also omit the Metal accelerator
and sampler. The stop-token patch adds Dawn to the common payload and the Metal
libraries on macOS. The builder and release verifier require all five Linux or
seven macOS vendor libraries, reject empty files and Git LFS pointers, and check
their hashes against the wheel. The macOS C API links with
`LC_RPATH=@loader_path`, so plugins are found next to the library without
`DYLD_*` variables.

## Accelerator ABI patches

The prebuilt vendor accelerators are built with Clang and
`ABSL_ATTRIBUTE_TRIVIAL_ABI` on `absl::Status`, so they expect `Status` returned
in registers. Pinned Abseil disables that attribute, which made the accelerator
crash in `LiteRtWeightLoader::PrepareAccessForBuffer`.

- `macos-trivial-abi.patch` enables the attribute for Apple arm64 Clang.
- `linux-trivial-abi.patch` does the same on Linux x86-64. Linux builds also
  compile with Clang against `libc++`, because the vendor binaries read
  `tflite::Subgraph` fields at `libc++` layout offsets, and statically link PIC
  `libc++.a` and `libc++abi.a`.

The Linux C API links with a version script that hides every symbol outside
`litert_lm_*`. The builder and release verifier reject dynamic C++ runtime or
`libunwind` linkage, and exports outside `litert_lm_*` apart from the ELF loader
symbols. They also require the ABI patch hash and a passing Status ABI report.
`tools/test_litert_status_abi.py` reproduces the crash with `libstdc++` or
unpatched Abseil headers and passes with `libc++` and the trivial-ABI patch.

## Build and package

Build from a clean checkout with its platform's Git LFS prebuilts materialized
(`prebuilt/macos_arm64/*` or `prebuilt/linux_x86_64/*`):

```sh
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/google-ai-edge/LiteRT-LM.git /tmp/litert-lm-source
GIT_LFS_SKIP_SMUDGE=1 git -C /tmp/litert-lm-source checkout b2f686e2ed4718fb84ec398a61dd59ca0f0aff27
git -C /tmp/litert-lm-source lfs install --local
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) task_litert_prebuilts=macos_arm64 ;;
  Linux:x86_64) task_litert_prebuilts=linux_x86_64 ;;
  *) printf 'Unsupported LiteRT build host\n' >&2; exit 1 ;;
esac
git -C /tmp/litert-lm-source lfs pull --include="prebuilt/$task_litert_prebuilts/*" --exclude=''
python3 tools/build_litert_extensions.py /tmp/litert-lm-source --bazel /path/to/bazel-7.6.1
```

On macOS, `tools/build_macos_vendor.py` performs these steps with a
checksum-verified Bazel; Linux CI builds it in `packaging/sdk-litert.Dockerfile`.
The helper checks the source revision, applies only the checked-in patches,
rejects unmaterialized LFS libraries, runs the native config-copy regression,
builds the API wheel, and writes a manifest of wheel, library, patch and log
hashes.

Both packagers accept the result through `--litert-extensions-manifest` and verify
it; the stock checksum policy applies when it is absent. Linux also needs the
matching library:

```sh
python3 tools/package.py \
  --litert-library build/litert-extensions/liblitert-lm.so \
  --litert-extensions-manifest build/litert-extensions/build-manifest.json
```

The packagers extract only the native C library and vendor libraries from the
wheel; no Python runtime ships. `tools/test_litert_stop_sequences.py` checks real
single- and multi-token stopping with the SDK's `test_lm.litertlm`.
