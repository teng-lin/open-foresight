#!/usr/bin/env bash
# Validate dependency changes in PRs without publishing images or registry caches.
set -euo pipefail
export DOCKER_BUILDKIT=1
docker build -f packaging/sdk-core.Dockerfile -t foresight-core:pr .
docker build -f packaging/sdk-litert.Dockerfile --build-arg CORE_IMAGE=foresight-core:pr -t foresight-litert:pr .
docker build -f packaging/sdk-whisper.Dockerfile --build-arg CORE_IMAGE=foresight-core:pr -t foresight-whisper:pr .
docker build -f packaging/sdk.Dockerfile --build-arg CORE_IMAGE=foresight-core:pr --build-arg LITERT_IMAGE=foresight-litert:pr --build-arg WHISPER_IMAGE=foresight-whisper:pr -t foresight-sdk:pr .
docker run --rm foresight-sdk:pr /opt/toolchain/bin/protoc --version
