# syntax=docker/dockerfile:1
# Reusable SDK is built separately; pass its immutable registry digest in CI.
ARG SDK_IMAGE=open-foresight-sdk:local
# Local developer builds may populate dependencies normally. CI replaces this
# empty context with verified existing outputs before any application build.
FROM scratch AS appdeps_seed
COPY packaging/app-dependencies/empty-seed/.keep /src/build/_deps/.keep
FROM ${SDK_IMAGE} AS application-base
ARG UBUNTU_SNAPSHOT=20261001T000000Z
ENV FORESIGHT_UBUNTU_SNAPSHOT=${UBUNTU_SNAPSHOT}
LABEL org.openforesight.ubuntu-snapshot="${UBUNTU_SNAPSHOT}"
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Header-only application dependency, independent of the expensive SDK build.
RUN apt-get --snapshot "$UBUNTU_SNAPSHOT" update && apt-get --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends nlohmann-json3-dev libicu-dev && \
    rm -rf /var/lib/apt/lists/*
# The cached SDK uses a shallow, commit-pinned Flutter checkout. Restore its
# matching release tag before pub resolves packages, verifying the tag cannot
# change the pinned framework revision. Discard the previously cached unknown
# version so Flutter derives it from that tag.
RUN git -C /opt/flutter fetch --depth=1 origin refs/tags/3.35.7:refs/tags/3.35.7 && \
    test "$(git -C /opt/flutter rev-parse refs/tags/3.35.7)" = "$(git -C /opt/flutter rev-parse HEAD)" && \
    rm -f /opt/flutter/bin/cache/flutter.version.json && \
    flutter --version --machine | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["frameworkVersion"] == "3.35.7" else "Unexpected Flutter framework version")'
WORKDIR /src

# The named context contains only qualified dependency outputs from an immutable
# main-produced cache; it never contains application code or an old test result.
FROM application-base AS application-dependencies
ARG REQUIRE_DEPENDENCY_REUSE=0
COPY --from=appdeps_seed /src/build/_deps /src/build/_deps
COPY packaging/app-dependencies/CMakeLists.txt /src/CMakeLists.txt
COPY cmake/ForesightInferenceDependencies.cmake /src/cmake/ForesightInferenceDependencies.cmake
COPY tools/verify_app_dependency_reuse.py /opt/foresight/verify_app_dependency_reuse.py
RUN cmake -G "Unix Makefiles" -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release && \
    test "$REQUIRE_DEPENDENCY_REUSE" = 0 -o "$REQUIRE_DEPENDENCY_REUSE" = 1 && \
    if [[ "$REQUIRE_DEPENDENCY_REUSE" == 1 ]]; then python3 /opt/foresight/verify_app_dependency_reuse.py --build /src/build; fi && \
    cmake --build /src/build --parallel 4

# Secret-free test environment shared by independent shadow build/test runners.
# This is application tooling; it never changes component SDK recipe identities.
FROM application-dependencies AS ci
LABEL org.openforesight.ci-handoff="source-scoped-sdk-transport"
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python \
    FORESIGHT_PARALLEL_GATES=1 FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=${REQUIRE_DEPENDENCY_REUSE}
RUN apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any --snapshot "$UBUNTU_SNAPSHOT" update && \
    apt-get -o Acquire::Retries=3 --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
      xvfb xauth dbus-x11 libgl1-mesa-dri mesa-vulkan-drivers poppler-utils unrtf bubblewrap gh && \
    rm -rf /var/lib/apt/lists/*
# The test image uses the flat scheduler by default; a runtime value of 0
# retains the legacy sequence without rebuilding this image or its dependencies.
ENV FORESIGHT_LINUX_TEST_SCHEDULE=1

# Source revisions invalidate application work while the dependency tree above
# stays reusable. Reconfiguration retains the same _deps paths and compiler flags.
FROM application-dependencies AS tested
COPY . .
ARG SOURCE_REVISION
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python FORESIGHT_PARALLEL_GATES=1 FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=${REQUIRE_DEPENDENCY_REUSE}
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
RUN apt-get --snapshot "$UBUNTU_SNAPSHOT" update && apt-get --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
    pipewire pipewire-pulse wireplumber pulseaudio-utils dbus-x11 mesa-vulkan-drivers && \
    rm -rf /var/lib/apt/lists/*

FROM scratch AS artifact
COPY --from=builder /src/dist/ /dist/
