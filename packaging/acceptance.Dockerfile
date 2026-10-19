# syntax=docker/dockerfile:1
# Acceptance consumes an already verified portable application mounted at
# /src/dist/open-foresight. This recipe has no application or SDK build step.
ARG SDK_IMAGE
FROM ${SDK_IMAGE}
ARG UBUNTU_SNAPSHOT=20261001T000000Z
RUN apt-get --snapshot "$UBUNTU_SNAPSHOT" update && apt-get --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
    pipewire pipewire-pulse wireplumber pulseaudio-utils dbus-x11 mesa-vulkan-drivers && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# Resolve test packages; retain the current pinned Flutter/Dart toolchain.
RUN cd packages/foresight_core && dart pub get --enforce-lockfile
RUN cd apps/desktop && flutter pub get --enforce-lockfile
