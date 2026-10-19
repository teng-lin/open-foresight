# syntax=docker/dockerfile:1
# Acceptance consumes an already verified portable application mounted at
# /src/dist/open-foresight. This recipe has no application or SDK build step.
ARG SDK_IMAGE
FROM ${SDK_IMAGE}
ARG UBUNTU_SNAPSHOT=20261001T000000Z
RUN apt-get --snapshot "$UBUNTU_SNAPSHOT" update && apt-get --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
    pipewire pipewire-pulse wireplumber pulseaudio-utils dbus-x11 mesa-vulkan-drivers && \
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
COPY . .
# Resolve test packages; retain the current pinned Flutter/Dart toolchain.
RUN cd packages/foresight_core && dart pub get --enforce-lockfile
RUN cd apps/desktop && flutter pub get --enforce-lockfile
