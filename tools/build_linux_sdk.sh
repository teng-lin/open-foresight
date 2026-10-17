#!/usr/bin/env bash
# Local x86-64 SDK build. Hosted CI publishes these components independently.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
# The default Docker driver can resolve the local parent images loaded below.
docker buildx build --builder default --platform linux/amd64 --load -f packaging/sdk-core.Dockerfile -t open-foresight-core:local .
docker buildx build --builder default --platform linux/amd64 --load -f packaging/sdk-litert.Dockerfile --build-arg CORE_IMAGE=open-foresight-core:local -t open-foresight-litert:local .
docker buildx build --builder default --platform linux/amd64 --load -f packaging/sdk-whisper.Dockerfile --build-arg CORE_IMAGE=open-foresight-core:local -t open-foresight-whisper:local .
docker buildx build --builder default --platform linux/amd64 --load -f packaging/sdk.Dockerfile --build-arg CORE_IMAGE=open-foresight-core:local --build-arg LITERT_IMAGE=open-foresight-litert:local --build-arg WHISPER_IMAGE=open-foresight-whisper:local -t open-foresight-sdk:local .
