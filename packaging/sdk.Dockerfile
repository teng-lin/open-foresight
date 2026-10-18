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

# Python tooling and Foresight workers change independently of vendor libraries.
WORKDIR /src
COPY requirements-dev.lock requirements-litert.lock ./
RUN python3 -m venv /opt/dev-python && /opt/dev-python/bin/pip install --no-cache-dir --require-hashes -r requirements-dev.lock && \
    python3 -m venv /opt/litert-python && /opt/litert-python/bin/pip install --no-cache-dir --require-hashes -r requirements-litert.lock
COPY --from=whisper /opt/whisper-sdk /opt/whisper-sdk
COPY services/speech /opt/services/speech
COPY services/inference/persistent_worker.h services/inference/output_budget.h services/inference/worker_frame.h /opt/services/inference/
RUN cmake -S /opt/services/speech -B /tmp/speech-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/whisper-sdk && \
    cmake --build /tmp/speech-build --parallel 2 && \
    cp /tmp/speech-build/bin/foresight-whisper-worker /opt/whisper-runtime/ && \
    rm -rf /tmp/speech-build /opt/services
