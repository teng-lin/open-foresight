# syntax=docker/dockerfile:1
# Acceptance consumes an already verified portable application mounted at
# /src/dist/open-foresight. This recipe has no application or SDK build step.
ARG SDK_IMAGE
FROM ${SDK_IMAGE} AS acceptance-dependencies
ARG UBUNTU_SNAPSHOT=20261001T000000Z
# Snapshot outages must not turn an incomplete update into misleading missing
# packages. Retain downloaded indexes/packages between bounded retries.
RUN for task_attempt in 1 2 3; do \
      if apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any --snapshot "$UBUNTU_SNAPSHOT" update && \
         apt-get -o Acquire::Retries=3 --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
           pipewire pipewire-pulse wireplumber pulseaudio-utils dbus-x11 mesa-vulkan-drivers; then \
        rm -rf /var/lib/apt/lists/*; exit 0; \
      fi; \
      if [[ "$task_attempt" == 3 ]]; then echo 'Acceptance package setup failed after three attempts' >&2; exit 1; fi; \
      sleep 10; \
    done
# The cached SDK uses a shallow, commit-pinned Flutter checkout. Restore its
# matching release tag before pub resolves packages, verifying the tag cannot
# change the pinned framework revision. Discard the previously cached unknown
# version so Flutter derives it from that tag.
RUN git -C /opt/flutter fetch --depth=1 origin refs/tags/3.35.7:refs/tags/3.35.7 && \
    test "$(git -C /opt/flutter rev-parse refs/tags/3.35.7)" = "$(git -C /opt/flutter rev-parse HEAD)" && \
    rm -f /opt/flutter/bin/cache/flutter.version.json && \
    flutter --version --machine | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["frameworkVersion"] == "3.35.7" else "Unexpected Flutter framework version")'
WORKDIR /src
# Only dependency declarations enter the reusable, main-published stage.
# Application/test edits keep package downloads and tool setup cached.
COPY packages/foresight_core/pubspec.yaml packages/foresight_core/pubspec.lock ./packages/foresight_core/
COPY packages/foresight_test_support/pubspec.yaml ./packages/foresight_test_support/
COPY apps/desktop/pubspec.yaml apps/desktop/pubspec.lock ./apps/desktop/
RUN cd packages/foresight_core && dart pub get --enforce-lockfile
RUN cd apps/desktop && flutter pub get --enforce-lockfile

FROM acceptance-dependencies AS acceptance
COPY . .
