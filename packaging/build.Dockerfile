# syntax=docker/dockerfile:1
# Reusable SDK is built separately; pass its immutable registry digest in CI.
ARG SDK_IMAGE=open-foresight-sdk:local
FROM ${SDK_IMAGE} AS tested
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
# Fetch this pinned runtime independently of application/source-revision changes.
COPY . .
ARG SOURCE_REVISION
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python FORESIGHT_PARALLEL_GATES=1
RUN test -n "$SOURCE_REVISION" && \
    ./tools/build.sh "-DFORESIGHT_BUILD_REVISION=$SOURCE_REVISION"
# Export only this tested, secret-free stage to the reusable registry cache.
# Packaging consumes the same local BuildKit result without exporting a fresh
# secret-bearing bundle to the cache on every release attempt.
FROM tested AS builder
ARG SOURCE_REVISION
# Application OAuth configuration is optional. BuildKit secrets never become
# build arguments/layers; the intentionally distributed application config is
# copied into the final bundle. Account tokens must never be supplied here.
# Secret contents do not invalidate BuildKit caches; refresh this final packaging
# layer for each release attempt so rotating distribution settings takes effect.
ARG DISTRIBUTION_CONFIG_REVISION=local
ARG REQUIRE_GOOGLE_CLIENT=0
RUN --mount=type=secret,id=google_client \
    --mount=type=secret,id=foresight_search_api_key \
    --mount=type=secret,id=foresight_web_content_api_key \
    test -n "$DISTRIBUTION_CONFIG_REVISION"; \
    task_args=(); if [[ "$REQUIRE_GOOGLE_CLIENT" == 1 ]]; then task_args+=(--require-google-client); fi; \
    if [[ -f /run/secrets/google_client ]]; then task_args+=(--google-client /run/secrets/google_client); fi; \
    if [[ -f /run/secrets/foresight_search_api_key ]]; then export FORESIGHT_SEARCH_API_KEY="$(cat /run/secrets/foresight_search_api_key)"; fi; \
    if [[ -f /run/secrets/foresight_web_content_api_key ]]; then export FORESIGHT_WEB_CONTENT_API_KEY="$(cat /run/secrets/foresight_web_content_api_key)"; fi; \
    /opt/dev-python/bin/python tools/package.py --output dist/open-foresight \
      --revision "$SOURCE_REVISION" \
      --litert-library /opt/litert-extensions/liblitert-lm.so \
      --litert-extensions-manifest /opt/litert-extensions/build-manifest.json \
      --generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli \
      --whisper-gpu-device 0 "${task_args[@]}" && \
    python3 packaging/check_abi.py dist/open-foresight --max-glibc 2.39 --report dist/abi.json

# Disposable acceptance runner; weights and reports are mounted at runtime.
# No host audio devices or host session sockets are passed to this image.
FROM builder AS integration
RUN apt-get update && apt-get install -y --no-install-recommends \
    pipewire pipewire-pulse wireplumber pulseaudio-utils dbus-x11 && \
    rm -rf /var/lib/apt/lists/*

FROM scratch AS artifact
COPY --from=builder /src/dist/ /dist/
