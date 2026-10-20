# syntax=docker/dockerfile:1
# Reusable SDK is built separately; pass its immutable registry digest in CI.
ARG TOOLING_IMAGE=foresight-ci-tooling:local
# Local tooling is built separately from the same verified SDK. CI prefers an
# immutable main-produced image only after its original receipt qualifies.
FROM scratch AS appdeps_seed
COPY packaging/app-dependencies/empty-seed/.keep /src/build/_deps/.keep
FROM ${TOOLING_IMAGE} AS application-base
WORKDIR /src

# The named context contains only qualified dependency outputs from an immutable
# main-produced cache; it never contains application code or an old test result.
FROM application-base AS application-dependencies
ARG REQUIRE_DEPENDENCY_REUSE=0
COPY --from=appdeps_seed /src/build/_deps /src/build/_deps
COPY packaging/app-dependencies/CMakeLists.txt /src/CMakeLists.txt
COPY cmake/ForesightInferenceDependencies.cmake /src/cmake/ForesightInferenceDependencies.cmake
COPY tools/verify_app_dependency_reuse.py /opt/foresight/verify_app_dependency_reuse.py
RUN cmake -G "Unix Makefiles" -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release && \
    test "$REQUIRE_DEPENDENCY_REUSE" = 0 -o "$REQUIRE_DEPENDENCY_REUSE" = 1 && \
    if [[ "$REQUIRE_DEPENDENCY_REUSE" == 1 ]]; then python3 /opt/foresight/verify_app_dependency_reuse.py --build /src/build; fi && \
    cmake --build /src/build --parallel 4

# Secret-free test environment shared by independent shadow build/test runners.
# This is application tooling; it never changes component SDK recipe identities.
FROM application-dependencies AS ci
LABEL org.openforesight.ci-handoff="source-scoped-sdk-transport"
ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python \
    FORESIGHT_PARALLEL_GATES=1 FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=${REQUIRE_DEPENDENCY_REUSE}
# The test image uses the flat scheduler by default; a runtime value of 0
# retains the legacy sequence without rebuilding this image or its dependencies.
ENV FORESIGHT_LINUX_TEST_SCHEDULE=1
