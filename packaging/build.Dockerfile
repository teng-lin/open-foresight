# syntax=docker/dockerfile:1
# Reusable SDK is built separately; pass its immutable registry digest in CI.
ARG SDK_IMAGE=open-foresight-sdk:local
FROM ${SDK_IMAGE} AS builder
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
WORKDIR /src
COPY . .
ARG SOURCE_REVISION
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python
RUN test -n "$SOURCE_REVISION" && \
    ./tools/build.sh "-DFORESIGHT_BUILD_REVISION=$SOURCE_REVISION"
# Application OAuth configuration is optional. BuildKit secrets never become
# build arguments/layers; the intentionally distributed application config is
# copied into the final bundle. Account tokens must never be supplied here.
RUN --mount=type=secret,id=google_client \
    task_args=(); if [[ -f /run/secrets/google_client ]]; then task_args+=(--google-client /run/secrets/google_client); fi; \
    /opt/dev-python/bin/python tools/package.py --output dist/open-foresight \
      --revision "$SOURCE_REVISION" --litert-python /opt/litert-python/bin/python \
      --generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli \
      --whisper-gpu-device 0 "${task_args[@]}" && \
    python3 packaging/check_abi.py dist/open-foresight --max-glibc 2.39 --report dist/abi.json

FROM scratch AS artifact
COPY --from=builder /src/dist/ /dist/
