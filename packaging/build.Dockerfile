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
