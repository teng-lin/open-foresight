#!/usr/bin/env bash
# Dedicated main-only writer of secret-free application and acceptance caches.
set -euo pipefail
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Cache publication requires main' >&2; exit 1; }
case "${GITHUB_EVENT_NAME:-}" in push|workflow_dispatch|schedule) ;; *) echo 'Cache publication requires a main event' >&2; exit 1 ;; esac
: "${SDK_IMAGE:?Verified SDK image required}"
task_repository=$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')
task_seed=${APP_DEPENDENCY_SEED:-build/app-dependency-seed}
for task_stage in '' --ci --acceptance; do
  python tools/ci_app_build_transport.py --repository "$task_repository" ${task_stage:+"$task_stage"}
done
if [[ -e "$task_seed" || -L "$task_seed" ]]; then
  python tools/ci_app_dependency_seed.py --sdk-image "$SDK_IMAGE" --output "$task_seed" --verify-existing
else
  python tools/ci_app_dependency_seed.py --sdk-image "$SDK_IMAGE" --output "$task_seed"
fi
task_builder=$(docker context show)
task_tooling=${TOOLING_IMAGE:-}
if [[ -z "$task_tooling" ]]; then
  task_snapshot=$(python -c 'import json; print(json.load(open("tools/pins.json"))["ubuntu_snapshot"])')
  task_tooling_dir=${CI_TOOLING_DIRECTORY:-build/cache-tooling}
  python tools/ci_tooling_image.py --repository "$task_repository" \
    --sdk-image "$SDK_IMAGE" --snapshot "$task_snapshot" --output "$task_tooling_dir"
  task_tooling=$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "$task_tooling_dir/inputs.json")
fi
task_namespace=${CI_CACHE_NAMESPACE:-legacy}
case "$task_namespace" in legacy|isolated-v2) ;; *) echo 'Unknown cache publication namespace' >&2; exit 1 ;; esac
for task_stage in application-dependencies ci acceptance-dependencies; do
  task_context=()
  task_recipe=packaging/build.Dockerfile
  task_cache=app-deps-buildcache-v1
  if [[ "$task_stage" == acceptance-dependencies ]]; then
    task_recipe=packaging/acceptance.Dockerfile
    task_cache=acceptance-tools-buildcache-v1
  else
    task_context=(--build-context "appdeps_seed=$task_seed" --build-arg REQUIRE_DEPENDENCY_REUSE=1 --build-arg "TOOLING_IMAGE=$task_tooling")
    if [[ "$task_stage" == ci ]]; then task_cache=ci-tools-buildcache-v1; fi
  fi
  if [[ "$task_namespace" == isolated-v2 ]]; then task_cache="qualified-v2-$task_cache"; fi
  docker buildx build --builder "$task_builder" --platform linux/amd64 \
    --file "$task_recipe" --target "$task_stage" --build-arg "SDK_IMAGE=$SDK_IMAGE" \
    ${task_context[@]+"${task_context[@]}"} \
    --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:$task_cache" \
    --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:app-deps-buildcache-v1" \
    --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:app-buildcache-x86-64" \
    --cache-to "type=registry,ref=ghcr.io/$task_repository/linux-sdk:$task_cache,mode=max,image-manifest=true" .
done
