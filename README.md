# Foresight

A local knowledge and meeting desktop application built with Flutter, a C++ retrieval helper, SQLite, and local inference workers. The current desktop target is Linux; macOS requires platform integration work.

## Source layout

- `apps/desktop`: Flutter interface, persistence, sources, meetings, and cited answers.
- `services/helper`: gRPC retrieval helper and local model workers.
- `native`: generation, speech, and audio capture adapters.
- `proto`: required service definitions and protocol descriptor.
- `tests`: reusable contract, lifecycle, and grounding tests with controlled fixtures.
- `tools`: build, packaging, model setup, and optional integration-test commands.
- `models/minilm-manifest.json`: pinned embedding download metadata; model weights are separate.

This repository starts with a fresh history. Reference screenshots, reverse-engineering reports, historical evaluation results, machine-specific environments, downloaded models, application profiles, and account credentials are excluded. Runtime fonts and images are retained because the interface uses them.

For the reference investigation workflow, see [Replicating Foresight with REA on Linux and herdr on Mac](docs/rea-linux-and-herdr-mac.md).

## Build

Requirements: Linux, a C++20 compiler, CMake, protobuf/gRPC development packages, SQLite3, nlohmann-json, Python, and Flutter with GTK3 Linux development dependencies. The source pins Flutter package dependencies; the originating toolchain used Flutter 3.35.7, protobuf 36.1, gRPC 1.83.1, and nlohmann-json 3.12.

```sh
uv venv .venv
uv pip install --python .venv/bin/python -r requirements-dev.txt
./tools/build.sh
python3 tools/package.py
./tools/run_desktop.sh
```

The launcher uses the desktop application profile. Building this source does not copy existing user data or model registrations. PDF/RTF import uses `pdftotext`/`unrtf`; recording requires PipeWire and `pw-record`.

## Local models

Model weights are downloaded separately and registered through the application. Gemma generation uses the pinned LiteRT runtime; Whisper supports registered CPU executables or an explicitly built Vulkan runtime.

```sh
uv pip install --python .venv/bin/python -r requirements-models.lock
python3 tools/download_embedding_fixture.py models/local/all-MiniLM-L6-v2
python3 native/setup_models.py --directory models/local/native
uv venv --python 3.12 .venv-litert
uv pip install --python .venv-litert/bin/python -r requirements-litert.txt
python3 tools/package.py --output dist/foresight-linux-gemma --litert-python "$PWD/.venv-litert/bin/python"
```

Choose an unused package output directory. Pass `--generation-backend gpu` to package Gemma GPU generation; Whisper GPU packaging accepts `--whisper-gpu-runtime` and `--whisper-gpu-device`. Validate device indices on the target machine.

## Google connections

Drive and Calendar use browser authorization. Supply your application OAuth configuration with `tools/package.py --google-client /path/to/google-client.json`, or use the application's configuration setting. Packaging does not inspect another application or copy account tokens. Keep configuration and tokens out of Git.

## Verification

```sh
python3 tools/verify_descriptor.py
python3 -m pytest tests/contracts tests/models/test_grounded_generation.py
cmake --build build --parallel
ctest --test-dir build --output-on-failure
cd apps/desktop
flutter test
flutter analyze
```

Real-model, capture and desktop integration tests are opt-in and require their corresponding installed tools/models. Reports and captures go under ignored `test-results/` or an explicitly selected output path.
