#!/usr/bin/env bash
# Run inside the secret-free ci image; /workspace is a read-only source export.
set -euo pipefail
: "${SOURCE_REVISION:?Exact source revision required}"
: "${SOURCE_DATE_EPOCH:?Source timestamp required}"
: "${OUT_UID:?Output owner required}"
: "${OUT_GID:?Output group required}"
[[ "$SOURCE_REVISION" =~ ^[a-f0-9]{40}$ && "$OUT_UID:$OUT_GID" =~ ^[0-9]+:[0-9]+$ ]]
mkdir -p /out
trap 'chown -R "$OUT_UID:$OUT_GID" /out' EXIT
# Match the source exclusions of .dockerignore. In particular, local account
# data and .env files must not enter the container or portable bundle.
export FORESIGHT_PYTHON=${FORESIGHT_PYTHON:-/opt/dev-python/bin/python}
bash /workspace/tools/copy_linux_source.sh /workspace /src
cd /src
export FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=${FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE:-1}
bash tools/build.sh --build-only "-DFORESIGHT_BUILD_REVISION=$SOURCE_REVISION"
task_args=()
if [[ "${REQUIRE_GOOGLE_CLIENT:-0}" == 1 ]]; then task_args+=(--require-google-client); fi
if [[ -f /run/secrets/google_client ]]; then task_args+=(--google-client /run/secrets/google_client); fi
if [[ -f /run/secrets/foresight_search_api_key ]]; then FORESIGHT_SEARCH_API_KEY="$(cat /run/secrets/foresight_search_api_key)"; export FORESIGHT_SEARCH_API_KEY; fi
if [[ -f /run/secrets/foresight_web_content_api_key ]]; then FORESIGHT_WEB_CONTENT_API_KEY="$(cat /run/secrets/foresight_web_content_api_key)"; export FORESIGHT_WEB_CONTENT_API_KEY; fi
"$FORESIGHT_PYTHON" tools/package.py --output dist/open-foresight --revision "$SOURCE_REVISION" \
  --litert-library /opt/litert-extensions/liblitert-lm.so \
  --litert-extensions-manifest /opt/litert-extensions/build-manifest.json \
  --generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli \
  --whisper-gpu-device 0 ${task_args[@]+"${task_args[@]}"}
"$FORESIGHT_PYTHON" packaging/check_abi.py dist/open-foresight --max-glibc 2.39 --report dist/abi.json
"$FORESIGHT_PYTHON" packaging/package_linux.py --bundle dist/open-foresight --format tar \
  --version "${VERSION:?Package version required}" --release "${RELEASE:-1}"
if [[ "${CI_TIER:-pr}" == preview ]]; then
  test -f .distribution-build.json
  cp .distribution-build.json dist/packages/distribution-stamp.json
fi
"$FORESIGHT_PYTHON" tools/ci_linux_handoff.py pack --root /src --directory /out/handoff \
  --revision "$SOURCE_REVISION" --inputs /ci-inputs.json --tier "${CI_TIER:-pr}" --label "${BUILD_LABEL:-}"
rm -rf -- /out/packages
cp -a dist/packages /out/packages
