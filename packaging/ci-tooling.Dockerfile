# syntax=docker/dockerfile:1
# Secret-free OS tooling is independent of application dependency objects.
ARG SDK_IMAGE
FROM ${SDK_IMAGE} AS ci-tooling
ARG UBUNTU_SNAPSHOT=20261001T000000Z
ARG CI_TOOLING_ID
ARG SDK_IMAGE_ID
LABEL org.openforesight.ci-tooling="${CI_TOOLING_ID}" \
      org.openforesight.sdk-image-id="${SDK_IMAGE_ID}" \
      org.openforesight.ubuntu-snapshot="${UBUNTU_SNAPSHOT}"
ENV FORESIGHT_UBUNTU_SNAPSHOT=${UBUNTU_SNAPSHOT}
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Keep the exact pinned snapshot and diagnostics across bounded retries.
RUN for task_attempt in 1 2 3; do \
      if apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any --snapshot "$UBUNTU_SNAPSHOT" update && \
         apt-get -o Acquire::Retries=3 --snapshot "$UBUNTU_SNAPSHOT" install -y --no-install-recommends \
           nlohmann-json3-dev libicu-dev libpipewire-0.3-dev xvfb xauth dbus-x11 libgl1-mesa-dri \
           mesa-vulkan-drivers poppler-utils unrtf bubblewrap gh; then \
        rm -rf /var/lib/apt/lists/*; break; \
      fi; \
      if [[ "$task_attempt" == 3 ]]; then echo 'CI tooling setup failed after three attempts' >&2; exit 1; fi; \
      sleep 10; \
    done
RUN git -C /opt/flutter fetch --depth=1 origin refs/tags/3.35.7:refs/tags/3.35.7 && \
    test "$(git -C /opt/flutter rev-parse refs/tags/3.35.7)" = "$(git -C /opt/flutter rev-parse HEAD)" && \
    rm -f /opt/flutter/bin/cache/flutter.version.json && \
    flutter --version --machine | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["frameworkVersion"] == "3.35.7" else "Unexpected Flutter framework version")'
WORKDIR /src
