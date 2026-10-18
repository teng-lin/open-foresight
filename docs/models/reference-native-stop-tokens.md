# Native stop-token sequences

The original Foresight bridge appends each nonempty `stop_token_ids` integer
sequence to `SessionConfig::GetMutableStopTokenIds()` before creating a
conversation. The public LiteRT-LM 0.18.0 C API and Python wrapper do not expose
that operation. Matching a decoded text substring does not configure that native
detector and is not an equivalent implementation.

`third_party/litert_lm/stop-token-sequences.patch` extends the exact upstream
commit `b2f686e2ed4718fb84ec398a61dd59ca0f0aff27`. Its C entry point copies a
sequence into the real `SessionConfig` through the upstream C++ accessor. Empty
sequences are ignored; order and duplicates are retained. The Python extension
applies this setter before the conversation config copies the session config.
The extension never dereferences an opaque object outside the source runtime.

The shared native generation worker accepts optional `stop_token_ids` in its
conversation JSON on Linux and macOS. It calls the extension before creating
the native conversation. Custom stops disable empty-history base reuse.
Requests with nonempty sequences fail explicitly on the stock library.
Ordinary conversations without sequences keep working with the stock library.
The worker advertises `native_stop_token_sequences` in `--probe` metadata;
the application can reject an unsupported runtime before batch error recovery.

Notes also request `use_default_output_limit: true` for plain conversations.
This leaves both the native session limit and per-send optional limit unset,
preserving the original native default, rather than imposing the ordinary
application output budget. Tool conversations reject this flag. Existing
bounded requests retain their configured limits.

Build the native extension and patched Python API from a clean checkout. This
example fetches Mac arm64 prebuilts; use `prebuilt/linux_x86_64/*` on Linux:

```sh
git clone https://github.com/google-ai-edge/LiteRT-LM.git /tmp/litert-lm-source
git -C /tmp/litert-lm-source checkout b2f686e2ed4718fb84ec398a61dd59ca0f0aff27
git -C /tmp/litert-lm-source lfs install --local
git -C /tmp/litert-lm-source lfs pull --include='prebuilt/macos_arm64/*' --exclude=''
python3 tools/build_litert_extensions.py /tmp/litert-lm-source --bazel /path/to/bazel-7.6.1
```

The helper checks the exact source revision, applies only the checked-in patch,
rejects unmaterialized Git LFS native libraries before compiling,
runs the native config-copy regression, and builds the API wheel from source.
It checks that the selected native regression actually ran and passed, retains
its log, verifies wheel metadata is `litert-lm-api==0.18.0`, extracts its native
C runtime, and writes wheel/library/patch/log hashes in a manifest. It does
not install the wheel into a
runtime or change the published stock-library checksum. The existing
`prepare_litert.py` artifact remains stock.

Both release packagers accept the source-built runtime through an explicit
`--litert-extensions-manifest`. They verify the exact upstream commit, the
checked-in patch hash, wheel/library/test-log hashes, API metadata, wheel
platform and embedded native-library hash. The stock checksum policy remains
the default when this option is absent.

For Mac, add the manifest to the normal packaging command, retaining the usual
build, SDK and signing options:

```sh
python3 tools/package_macos.py \
  --litert-extensions-manifest build/litert-extensions/build-manifest.json
```

The Mac packager extracts only the authenticated arm64 C API and vendor dylibs
from the build wheel. It rejects non-arm64 payloads and escaping paths, relocates
their loader dependencies, signs the app, and checks the native worker. No Python
runtime or inference scripts are included. Source-artifact provenance ships with
the licenses; signing can change final bytes, so input hashes are not final
signed-file hashes.

For Linux, select the matching source-built library as well:

```sh
python3 tools/package.py \
  --litert-library build/litert-extensions/liblitert-lm.so \
  --litert-extensions-manifest build/litert-extensions/build-manifest.json
```

The selected library must match the manifest. The packager copies the four
pinned native vendor libraries from the verified wheel, requires x86_64 ELF
payloads, and validates their loader dependencies with the bundle's library
directory. Missing libraries, vendor libraries resolved outside the bundle,
and other dependencies outside the bundle or system library directories are
rejected. The copied native setter and generation worker must pass capability
checks. No Python interpreter is added to the Linux application.

`tools/test_litert_stop_sequences.py` exercises real generation with the pinned
SDK's `runtime/testdata/test_lm.litertlm` using an isolated wheel extraction and
Python 3.13. It compares a deterministic four-token baseline with an unmatched
ordered sequence and a matching two-token sequence. This separates a native
sequence detector from treating the IDs as an unordered stop set. It writes the
observed output and model hash only after the assertions pass; this test has no
Python text-stopping substitute.

The shared native tool-protocol and grounding tests cover the shipped worker.
Historical source-build evidence follows. The Mac arm64 source library and API wheel built successfully, and the
exact native config-copy regression ran once and passed. An isolated extraction
of the wheel loaded successfully and exercised the exported native setter on a
real session config without changing the installed runtime.

The build logs are retained under `test-results/reference-functions/ida/`
(`native-stop-source-build.log`, `native-stop-extension-build.log`). The wheel,
native library, selected-test log and hash manifest are under
`test-results/reference-functions/native-stop-runtime/`. The isolated SDK model
check also passes: a four-token baseline and unmatched ordered sequence both
produce four tokens, while the matching two-token sequence stops with empty
output. The observed model hash and outputs are retained in `model-check.json`;
the raw log is `ida/native-stop-model-check.log`. This does not establish parity
with Foresight's production generation model. Fifteen packaging verification,
isolation, probe and Linux dependency-policy tests pass, and the actual built
Mac manifest verifies successfully. Complete Mac copy/relocation/signing
acceptance, a Linux source build, and real Linux release acceptance remain
unverified; these unit checks do not establish those broader results.
