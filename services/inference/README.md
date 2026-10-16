# Native inference

`foresight-model` is a C++ worker shared by the retrieval helper and native
generation adapter. Distributed applications contain no Python interpreter,
Python scripts, or Python inference packages. Python remains a build/test tool.

- LiteRT-LM 0.18.0 uses Google's public C API for Gemma generation and
  EmbeddingGemma 2. Engine configuration, streaming, structured JSON, bounded
  output, citation checks, numeric fidelity, evidence selection, repair,
  independent support verification and attributed fallback run natively.
- SentencePiece and verified FlatBuffers metadata replace Python tokenization
  and model-header parsing. Embedding task prefixes, special tokens, 768-element
  L2 normalization, 512-token chunk averaging and the checksum-specific reference
  preprocessing convention are preserved.
- ONNX Runtime 1.31.0 supports local uncased BERT WordPiece directories with
  mean pooling, including the pinned all-MiniLM-L6-v2 fixture. Its native tokenizer
  uses ICU normalization. Long inputs retain the existing normalized window-mean
  policy. Other SentenceTransformers architectures require a supported native
  export/backend; arbitrary Python model implementations are not loaded.
- Generation keeps the existing separate-process boundary. The application
  service owns its process group, cancellation and timeout. Desktop and MCP
  continue using that same service. No model or runtime download happens inside
  the inference worker.

## Build and package

Build dependencies include OpenSSL and ICU development files. CMake fetches
pinned SentencePiece 0.2.1 and FlatBuffers sources; cached/offline sources can be
supplied with the standard `FETCHCONTENT_SOURCE_DIR_*` CMake options. Public
LiteRT and ONNX headers/licenses are under `third_party`.

```sh
python3 tools/prepare_litert.py build/lib/liblitert-lm.so
python3 tools/prepare_onnx.py build/lib/libonnxruntime.so
./tools/build.sh
python3 tools/package.py --generation-backend gpu
```

Preparation verifies pinned archive and library SHA-256 hashes. LiteRT's Python
wheel is used only as a transport for its standalone C shared library. No Python
files are extracted. Packaging checks both native library hashes, includes the
required native dependencies and licenses, and sets worker/library paths
relative to the bundle.

For source builds the worker also finds libraries under `build/lib`. Explicit
paths are available through `FORESIGHT_LITERT_LIBRARY`, `FORESIGHT_ONNX_LIBRARY`
and `FORESIGHT_MODEL_WORKER`. `FORESIGHT_LITERT_RUNNER` overrides old registered
LiteRT runner paths when restoring a packaged profile.

## Existing installations

Stop the existing application service before launching an upgraded bundle, so
clients connect to the new owner. Existing `.litertlm` model files remain usable. LiteRT embeddings retain their
identity and preprocessing fingerprint; CPU/GPU identity boundaries remain
separate. Packaged generation restores through the bundled native worker even
when the profile contains an obsolete Python runner path.

An old MiniLM directory needs its matching native export once:

```sh
python3 tools/download_embedding_fixture.py /path/to/all-MiniLM-L6-v2 --native
```

This command verifies the pinned ONNX model. Re-register the directory afterward;
the helper rebuilds the index atomically because the model directory digest and
backend changed. A failed replacement preserves the previous active generation.
The application recognizes a missing export as incomplete model setup. There is
no interpreter fallback. All Gemma setup and downloads remain available normally.

## Verification

`native_grounding_test` replays the former grounding regression cases with a
controlled native generator. `helper_model_lifetime` uses a compiled fixture to
check creator-thread retirement, closed frontend stderr, worker death, forced
cleanup and parent death. Existing helper, FFI and service/MCP tests remain in
place.

`tools/test_native_inference.py` exercises real models with an empty executable
PATH, so inference cannot discover Python or shell commands. Its optional
`--reference-python` runs the retired adapter separately as a test oracle only.
Reference Python implementations live in `tests/reference/inference` and are
never packaged. Real-model reports go under ignored `test-results`.

Verified on the implementation host with CPU and GPU EmbeddingGemma bundles,
MiniLM ONNX, GPU Gemma E2B, service/MCP restoration and a relocated desktop
bundle. Other Gemma sizes and independent clean machines require their own
acceptance checks; the port does not establish new GPU/model compatibility.
