# syntax=docker/dockerfile:1
# Reusable SDK is built separately; pass its immutable registry digest in CI.
ARG SDK_IMAGE=open-foresight-sdk:local
FROM ${SDK_IMAGE} AS builder
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Header-only application dependency, independent of the expensive SDK build.
RUN apt-get update && apt-get install -y --no-install-recommends nlohmann-json3-dev libicu-dev && \
    rm -rf /var/lib/apt/lists/*
# The cached SDK uses a shallow, commit-pinned Flutter checkout. Restore its
# matching release tag before pub resolves packages, verifying the tag cannot
# change the pinned framework revision. Discard the previously cached unknown
# version so Flutter derives it from that tag.
RUN git -C /opt/flutter fetch --depth=1 origin refs/tags/3.35.7:refs/tags/3.35.7 && \
    test "$(git -C /opt/flutter rev-parse refs/tags/3.35.7)" = "$(git -C /opt/flutter rev-parse HEAD)" && \
    rm -f /opt/flutter/bin/cache/flutter.version.json && \
    flutter --version --machine | python3 -c 'import json, sys; assert json.load(sys.stdin)["frameworkVersion"] == "3.35.7"'
WORKDIR /src
COPY . .
ARG SOURCE_REVISION
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python
RUN python3 tools/prepare_litert.py build/lib/liblitert-lm.so && \
    python3 tools/prepare_onnx.py build/lib/libonnxruntime.so
RUN test -n "$SOURCE_REVISION" && \
    ./tools/build.sh "-DFORESIGHT_BUILD_REVISION=$SOURCE_REVISION"
# Application OAuth configuration is optional. BuildKit secrets never become
# build arguments/layers; the intentionally distributed application config is
# copied into the final bundle. Account tokens must never be supplied here.
RUN --mount=type=secret,id=google_client \
    task_args=(); if [[ -f /run/secrets/google_client ]]; then task_args+=(--google-client /run/secrets/google_client); fi; \
    /opt/dev-python/bin/python tools/package.py --output dist/open-foresight \
      --revision "$SOURCE_REVISION" \
      --generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli \
      --whisper-gpu-device 0 "${task_args[@]}" && \
    python3 packaging/check_abi.py dist/open-foresight --max-glibc 2.39 --report dist/abi.json

FROM scratch AS artifact
COPY --from=builder /src/dist/ /dist/
