#!/usr/bin/env bash
# Shared local/CI driver. SDKs and qualified _deps are reused before app builds.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$task_root"
task_python=${FORESIGHT_HOST_PYTHON:-python3}
task_sdk=${SDK_IMAGE:-open-foresight-sdk:local}
task_seed=${APP_DEPENDENCY_SEED:-$task_root/build/app-dependency-seed}
task_output=${LINUX_BUILD_OUTPUT:-$task_root/build/portable}
task_mode=all
task_google=${FORESIGHT_GOOGLE_CLIENT_FILE:-}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-image) task_sdk=${2:?Missing SDK image}; shift 2 ;;
    --seed) task_seed=${2:?Missing verified dependency seed}; shift 2 ;;
    --output) task_output=${2:?Missing output}; shift 2 ;;
    --google-client) task_google=${2:?Missing Google application config}; shift 2 ;;
    --build-only|--test-only|--prepare-only) task_mode=${1#--}; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$task_output"
task_output=$(cd -- "$task_output" && pwd)
if [[ -e "$task_seed" || -L "$task_seed" ]]; then
  "$task_python" tools/ci_app_dependency_seed.py --sdk-image "$task_sdk" --output "$task_seed" --verify-existing
else
  "$task_python" tools/ci_app_dependency_seed.py --sdk-image "$task_sdk" --output "$task_seed"
fi
task_seed=$(cd -- "$task_seed" && pwd)
task_repository=${GITHUB_REPOSITORY:-teng-lin/open-foresight}
task_repository=${task_repository,,}
task_image=foresight-ci:local
task_builder=${FORESIGHT_BUILDER:-$(docker context show)}
docker buildx build --builder "$task_builder" --platform linux/amd64 --load \
  --file packaging/build.Dockerfile --target ci \
  --build-context "appdeps_seed=$task_seed" --build-arg "SDK_IMAGE=$task_sdk" \
  --build-arg REQUIRE_DEPENDENCY_REUSE=1 \
  --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:app-deps-buildcache-v1" \
  --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:app-buildcache-x86-64" \
  --tag "$task_image" .
task_snapshot=$("$task_python" -c 'import json; print(json.load(open("tools/pins.json"))["ubuntu_snapshot"])')
"$task_python" tools/ci_linux_handoff.py identity --sdk-image "$task_sdk" \
  --qualification "$task_seed/qualification.json" --snapshot "$task_snapshot" \
  --output "$task_output/ci-inputs.json"
if [[ "$task_mode" == prepare-only ]]; then exit 0; fi
export SOURCE_REVISION=${SOURCE_REVISION:-$(git rev-parse HEAD)}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD)}
export VERSION=${VERSION:-$("$task_python" tools/app_version.py)}
export CI_TIER=${CI_TIER:-local}
export RELEASE=${RELEASE:-1} OUT_UID=${OUT_UID:-$(id -u)} OUT_GID=${OUT_GID:-$(id -g)}
task_secrets=$(mktemp -d "${TMPDIR:-/tmp}/foresight-distribution.XXXXXX")
trap 'rm -rf -- "$task_secrets"' EXIT
task_mounts=()
if [[ -n "$task_google" ]]; then
  task_google=$(realpath -- "$task_google")
  [[ -f "$task_google" ]] || { echo 'Google application config is missing' >&2; exit 1; }
  task_mounts+=(-v "$task_google:/run/secrets/google_client:ro")
elif [[ -n "${FORESIGHT_GOOGLE_CLIENT_JSON:-}" ]]; then
  printf '%s' "$FORESIGHT_GOOGLE_CLIENT_JSON" > "$task_secrets/google_client"
  task_mounts+=(-v "$task_secrets/google_client:/run/secrets/google_client:ro")
fi
if [[ -n "${FORESIGHT_SEARCH_API_KEY:-}" ]]; then
  printf '%s' "$FORESIGHT_SEARCH_API_KEY" > "$task_secrets/search_key"
  task_mounts+=(-v "$task_secrets/search_key:/run/secrets/foresight_search_api_key:ro")
fi
if [[ -n "${FORESIGHT_WEB_CONTENT_API_KEY:-}" ]]; then
  printf '%s' "$FORESIGHT_WEB_CONTENT_API_KEY" > "$task_secrets/web_key"
  task_mounts+=(-v "$task_secrets/web_key:/run/secrets/foresight_web_content_api_key:ro")
fi
task_env=(-e SOURCE_REVISION -e SOURCE_DATE_EPOCH -e VERSION -e RELEASE -e OUT_UID -e OUT_GID
  -e CI_TIER -e BUILD_LABEL -e REQUIRE_GOOGLE_CLIENT -e GITHUB_REPOSITORY -e GITHUB_WORKFLOW -e GITHUB_RUN_ID -e GITHUB_RUN_ATTEMPT -e GITHUB_RUN_NUMBER -e FORESIGHT_CORE_COVERAGE_BENCHMARK -e FORESIGHT_QUERY_TERMS_URL)
if [[ "$task_mode" != test-only ]]; then
  docker run --rm "${task_env[@]}" ${task_mounts[@]+"${task_mounts[@]}"} \
    -v "$task_root:/workspace:ro" -v "$task_output:/out" -v "$task_output/ci-inputs.json:/ci-inputs.json:ro" \
    "$task_image" bash /workspace/tools/linux_container_build.sh
fi
if [[ "$task_mode" != build-only ]]; then
  mkdir -p "$task_output/evidence"
  task_security=(--cap-add SYS_PTRACE --security-opt seccomp=unconfined --security-opt systempaths=unconfined)
  if [[ -n "${FORESIGHT_CONTAINER_APPARMOR:-}" ]]; then
    task_security+=(--security-opt "apparmor=$FORESIGHT_CONTAINER_APPARMOR")
  fi
  docker run --rm "${task_security[@]}" \
    "${task_env[@]}" -v "$task_root:/workspace:ro" -v "$task_output/evidence:/out" \
    -v "$task_output/ci-inputs.json:/ci-inputs.json:ro" -v "$task_output/handoff:/handoff:ro" \
    "$task_image" bash /workspace/tools/linux_container_test.sh
fi
if [[ "$task_mode" == all ]]; then
  task_package="open-foresight-$VERSION-$RELEASE-linux-x86_64.tar.gz"
  (cd "$task_output/packages" && sha256sum --check "$task_package.sha256")
  mkdir -p "$task_output/dist"
  "$task_python" -m tarfile --extract "$task_output/packages/$task_package" "$task_output/dist" --filter data
fi
