# syntax=docker/dockerfile:1
ARG CORE_IMAGE
FROM ${CORE_IMAGE} AS litert-extensions
RUN apt-get update && apt-get install -y --no-install-recommends git-lfs libc++-dev libc++abi-dev zip && \
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
COPY tools/litert_extensions.py /opt/foresight-extension/tools/litert_extensions.py
COPY tools/test_litert_status_abi.py /opt/foresight-extension/tools/test_litert_status_abi.py
COPY third_party/litert_lm/stop-token-sequences.patch /opt/foresight-extension/third_party/litert_lm/stop-token-sequences.patch
COPY third_party/litert_lm/linux-trivial-abi.patch /opt/foresight-extension/third_party/litert_lm/linux-trivial-abi.patch
RUN --mount=type=cache,target=/tmp/litert-bazel \
    python3 /opt/foresight-extension/tools/build_litert_extensions.py /opt/litert-source \
      --output /opt/litert-extensions --output-user-root /tmp/litert-bazel --jobs 2 && \
    rm -rf /opt/litert-source
