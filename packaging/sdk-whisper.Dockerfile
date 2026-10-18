# syntax=docker/dockerfile:1
ARG CORE_IMAGE
FROM ${CORE_IMAGE} AS whisper
ARG WHISPER_COMMIT=0c7be696371069e0baa2515ed7aa08d5a5473aa6
RUN git init /opt/whisper && cd /opt/whisper && git remote add origin https://github.com/ggml-org/whisper.cpp.git && \
    git fetch --depth=1 origin "$WHISPER_COMMIT" && git checkout --detach FETCH_HEAD

ARG SPIRV_HEADERS_COMMIT=86f980c731e62ae4eaf383d320449d71687936bf
RUN git init /opt/spirv-source && cd /opt/spirv-source && \
    git remote add origin https://github.com/KhronosGroup/SPIRV-Headers.git && \
    git fetch --depth=1 origin "$SPIRV_HEADERS_COMMIT" && git checkout --detach FETCH_HEAD && \
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/opt/spirv-headers \
      -DSPIRV_HEADERS_ENABLE_TESTS=OFF -DSPIRV_HEADERS_ENABLE_INSTALL=ON && \
    cmake --install build && rm -rf /opt/spirv-source
COPY tools/build_whisper_vulkan.py /opt/tools/build_whisper_vulkan.py
RUN python3 /opt/tools/build_whisper_vulkan.py --source /opt/whisper --build /opt/whisper-build --output /opt/whisper-runtime --spirv-prefix /opt/spirv-headers --jobs 2 && \
    rm -rf /opt/whisper-build /opt/whisper
