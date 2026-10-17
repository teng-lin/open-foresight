# syntax=docker/dockerfile:1
# Ubuntu 24.04 / glibc 2.39 is the supported binary baseline. Build *all*
# native components here, including Whisper and the isolated Python runtime.
FROM ubuntu:24.04 AS core
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive CI=true FLUTTER_SUPPRESS_ANALYTICS=true
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang cmake ninja-build git curl ca-certificates pkg-config \
    libgtk-3-dev libblkid-dev liblzma-dev libsqlite3-dev libssl-dev zlib1g-dev \
    python3-dev python3-venv libvulkan-dev glslc glslang-tools \
    unzip xz-utils && rm -rf /var/lib/apt/lists/*

# gRPC 1.83.1 includes protobuf 7.35.1 with Edition 2024 C++ generation.
ARG GRPC_COMMIT=aae267021b1ac256f8b9038d0ef528c3798cc137
COPY packaging/minimal-grpc.cmake /opt/minimal-grpc.cmake
RUN git init /opt/grpc && cd /opt/grpc && git remote add origin https://github.com/grpc/grpc.git && \
    git fetch --depth=1 origin "$GRPC_COMMIT" && git checkout --detach FETCH_HEAD && \
    git submodule update --init --recursive --depth=1 && \
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/toolchain -DCMAKE_CXX_STANDARD=20 \
      -DCMAKE_PROJECT_grpc_INCLUDE=/opt/minimal-grpc.cmake \
      '-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG' '-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG' \
      -DCMAKE_CXX_FLAGS='-march=x86-64 -mtune=generic' \
      -DBUILD_SHARED_LIBS=ON -DgRPC_BUILD_TESTS=OFF -Dprotobuf_BUILD_TESTS=OFF -DRE2_BUILD_TESTING=OFF \
      -DgRPC_SSL_PROVIDER=package -DgRPC_ZLIB_PROVIDER=package \
      -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_PYTHON_PLUGIN=OFF -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF && \
    cmake --build build --parallel 2 && cmake --install build && \
    rm -rf /opt/grpc
ENV PATH=/opt/flutter/bin:/opt/toolchain/bin:${PATH} \
    CMAKE_PREFIX_PATH=/opt/toolchain LD_LIBRARY_PATH=/opt/toolchain/lib

ARG FLUTTER_COMMIT=adc901062556672b4138e18a4dc62a4be8f4b3c2
RUN git init /opt/flutter && cd /opt/flutter && git remote add origin https://github.com/flutter/flutter.git && \
    git fetch --depth=1 origin "$FLUTTER_COMMIT" && git checkout --detach FETCH_HEAD && \
    flutter config --no-analytics && flutter precache --linux

ARG WHISPER_COMMIT=0c7be696371069e0baa2515ed7aa08d5a5473aa6
RUN git init /opt/whisper && cd /opt/whisper && git remote add origin https://github.com/ggml-org/whisper.cpp.git && \
    git fetch --depth=1 origin "$WHISPER_COMMIT" && git checkout --detach FETCH_HEAD

WORKDIR /src
COPY requirements-dev.lock requirements-litert.lock ./
RUN python3 -m venv /opt/dev-python && /opt/dev-python/bin/pip install --no-cache-dir --require-hashes -r requirements-dev.lock && \
    python3 -m venv /opt/litert-python && /opt/litert-python/bin/pip install --no-cache-dir --require-hashes -r requirements-litert.lock
# Build the C API required by note enhancement rather than shipping the stock
# wheel, which has no native ordered-stop setter. Keep this stage independent
# from Whisper so either expensive build can reuse its completed layers.
FROM core AS litert-extensions
RUN apt-get update && apt-get install -y --no-install-recommends git-lfs zip && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fL --retry 3 -o /usr/local/bin/bazel \
      https://github.com/bazelbuild/bazel/releases/download/7.6.1/bazel-7.6.1-linux-x86_64 && \
    echo 'ac6249d1192aea9feaf49dfee2ab50c38cee2454b00cf29bbec985a11795c025  /usr/local/bin/bazel' | sha256sum -c - && \
    chmod +x /usr/local/bin/bazel
ARG LITERT_LM_COMMIT=b2f686e2ed4718fb84ec398a61dd59ca0f0aff27
RUN git init /opt/litert-source && cd /opt/litert-source && \
    git remote add origin https://github.com/google-ai-edge/LiteRT-LM.git && \
    git fetch --depth=1 origin "$LITERT_LM_COMMIT" && \
    GIT_LFS_SKIP_SMUDGE=1 git checkout --detach FETCH_HEAD && \
    git lfs install --local && git lfs pull --include='prebuilt/linux_x86_64/*' --exclude=''
COPY tools/build_litert_extensions.py /opt/foresight-extension/tools/build_litert_extensions.py
COPY third_party/litert_lm/stop-token-sequences.patch /opt/foresight-extension/third_party/litert_lm/stop-token-sequences.patch
RUN --mount=type=cache,target=/tmp/litert-bazel \
    python3 /opt/foresight-extension/tools/build_litert_extensions.py /opt/litert-source \
      --output /opt/litert-extensions --output-user-root /tmp/litert-bazel --jobs 2 && \
    rm -rf /opt/litert-source

# Publish/cache the core before building the GPU runner. Shader dependency
# failures must not discard a successful gRPC/Flutter/Python bootstrap.
FROM core AS sdk
COPY --from=litert-extensions /opt/litert-extensions /opt/litert-extensions
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
