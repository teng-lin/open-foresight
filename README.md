# Open Foresight

A local knowledge and meeting desktop application built with Flutter, a C++ retrieval helper, SQLite, and local inference workers. The current desktop target is Linux; macOS requires platform integration work.

See the [macOS support implementation plan](docs/macos-support-plan.md) for the proposed port built on the application-service and MCP refactor.

## Source layout

- `apps/desktop`: Flutter interface, persistence, sources, meetings, and cited answers.
- `services/helper`: gRPC retrieval helper.
- `services/inference`: native LiteRT/ONNX inference and grounding worker.
- `native`: generation, speech, and audio capture adapters.
- `proto`: required service definitions and protocol descriptor.
- `tests`: reusable contract, lifecycle, and grounding tests with controlled fixtures.
- `tools`: build, packaging, model setup, and optional integration-test commands.
- `models/minilm-manifest.json`: pinned embedding download metadata; model weights are separate.

This repository starts with a fresh history. Reference screenshots, reverse-engineering reports, historical evaluation results, machine-specific environments, downloaded models, application profiles, and account credentials are excluded. Runtime fonts and images are retained because the interface uses them.

For the reference investigation workflow, see [Replicating Foresight with REA on Linux and herdr on Mac](docs/rea-linux-and-herdr-mac.md).

## Build

Requirements: Linux, a C++20 compiler, CMake, protobuf/gRPC development packages, SQLite3, nlohmann-json, OpenSSL, ICU, Python for build/test tooling, and Flutter with GTK3 Linux development dependencies. The source pins Flutter package dependencies; the originating toolchain used Flutter 3.35.7, protobuf 36.1, gRPC 1.83.1, and nlohmann-json 3.12.

```sh
uv venv .venv
uv pip install --python .venv/bin/python -r requirements-dev.txt
python3 tools/prepare_litert.py build/lib/liblitert-lm.so
python3 tools/prepare_onnx.py build/lib/libonnxruntime.so
./tools/build.sh
python3 tools/package.py
./tools/run_desktop.sh
```

The executable is `dist/open-foresight/open-foresight`; `./tools/run_desktop.sh` launches it. The profile lives in `$XDG_DATA_HOME/open-foresight` (normally `~/.local/share/open-foresight`), with sockets in `$XDG_RUNTIME_DIR/open-foresight`. `FORESIGHT_DATA` and `FORESIGHT_RUNTIME` override these paths for isolated sessions. Legacy profiles are never selected implicitly. To migrate an existing desktop profile, stop its app and helper, then run:

```sh
python3 tools/migrate_profile.py ~/.local/share/foresight-linux-desktop \
  ~/.local/share/open-foresight --backup ~/.local/state/open-foresight/profile-backup \
  --old-bundle /path/to/old/dist/foresight \
  --new-bundle "$PWD/dist/open-foresight" --copy-external-models
```

Migration refuses active owners, unfinished recordings, and existing destinations. It preserves a private backup, checks SQLite integrity, updates owned model/file paths, and optionally copies external model assets so other sessions retain their originals. Model downloads and GPU caches inside the profile move intact. Backups contain private application data; keep them outside Git. PDF/RTF import uses `pdftotext`/`unrtf`; recording requires PipeWire and `pw-record`.

## Local models

First launch offers Gemma 4 12B, E4B, and E2B using the reference memory requirements of 30, 15, and 6 GB. Setup downloads the missing EmbeddingGemma 2 source-search model and selected generation model, verifies pinned sizes and SHA-256 hashes, and registers each only after loading succeeds. Completed files and registrations survive a later failure or restart; cancellation removes owned partial downloads. Settings can reopen model selection or register existing local files. The packaged native LiteRT runtime supports automatic setup; users do not need Python. Linux uses public LiteRT model artifacts and a GPU runtime rather than the Mac service’s encrypted artifacts. System RAM eligibility does not guarantee a model fits the selected GPU. Settings → Transcription Model offers multilingual Whisper Tiny, Base, Small, Medium, and Large v3 Turbo. Existing English-only registrations remain selected until changed; automatic language detection preserves Chinese and English speech. See [speech model behavior and validation](docs/speech-models.md). Gemma generation uses the pinned LiteRT runtime; Whisper supports registered CPU executables or an explicitly built Vulkan runtime.

```sh
# Optional native compatibility model; the app also offers EmbeddingGemma setup.
python3 tools/download_embedding_fixture.py models/local/all-MiniLM-L6-v2 --native
# Optional CPU generation and speech runtimes:
python3 native/setup_models.py --directory models/local/native
python3 tools/package.py --output dist/open-foresight-gemma --generation-backend gpu
```

The distributed app uses native C++ inference and has no Python runtime dependency. Existing MiniLM directories need the pinned ONNX export and re-registration. See [native inference, migration, and verification](services/inference/README.md).

Choose an unused package output directory. Pass `--generation-backend gpu` to package Gemma GPU generation; Whisper GPU packaging accepts `--whisper-gpu-runtime` and `--whisper-gpu-device`. Validate device indices on the target machine.

## Application service and MCP

The desktop and MCP clients share one local application service per profile. It owns database writes, models, imports, and meeting recording independently of the desktop window. Use `dist/open-foresight/open-foresight-mcp` as a stdio MCP server. See [setup, tools, lifecycle, and verification](docs/application-service.md).

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
