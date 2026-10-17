# syntax=docker/dockerfile:1
# Component images are verified, independently cached and passed by digest.
ARG CORE_IMAGE
ARG LITERT_IMAGE
ARG WHISPER_IMAGE
FROM ${LITERT_IMAGE} AS litert
FROM ${WHISPER_IMAGE} AS whisper
FROM ${CORE_IMAGE} AS sdk
COPY --from=litert /opt/litert-extensions /opt/litert-extensions
COPY --from=whisper /opt/whisper-runtime /opt/whisper-runtime
COPY --from=whisper /opt/spirv-headers /opt/spirv-headers
