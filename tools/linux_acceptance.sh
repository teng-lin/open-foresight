#!/usr/bin/env bash
# Independent consumers of verified portable bytes; no application/SDK build.
set -euo pipefail
task_suite=${1:?cpu, audio, or deb}
: "${VERSION:?Original package version required}"
if [[ "$task_suite" == deb ]]; then
  bash tools/ci_package_sandbox.sh
  export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD)}
  docker run --rm --cap-add NET_ADMIN --security-opt seccomp=unconfined --security-opt systempaths=unconfined --security-opt apparmor=foresight-ci-document-sandbox \
    -v "$PWD:/work" -w /work -e SOURCE_DATE_EPOCH \
    ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac \
    bash packaging/ci/package-and-test.sh deb "$VERSION" 1
  if [[ "${ACCEPTANCE_FULL:-false}" == true || "${PACKAGING_SELECTED:-false}" == true ]]; then
    docker run --rm --cap-add NET_ADMIN --security-opt seccomp=unconfined --security-opt systempaths=unconfined --security-opt apparmor=foresight-ci-document-sandbox \
      -v "$PWD:/work:ro" -v "$PWD/dist/packages:/packages:ro" \
      debian:13@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5 \
      bash /work/packaging/ci/test-debian.sh
  fi
  exit 0
fi
[[ "$task_suite" == cpu || "$task_suite" == audio ]] || { echo 'Unknown acceptance suite' >&2; exit 2; }
# Each omitted phase is authorized in the retained changes-job report. Manual,
# preview, release and nightly plans always select every phase.
for task_phase in "${CPU_MODELS_SELECTED:-true}" "${SOFTWARE_GPU_SELECTED:-true}" "${VIRTUAL_AUDIO_SELECTED:-true}"; do
  [[ "$task_phase" == true || "$task_phase" == false ]] || { echo 'Malformed acceptance phase selection' >&2; exit 2; }
done
if [[ "$task_suite" == cpu && "${CPU_MODELS_SELECTED:-true}" == false ]] || [[ "$task_suite" == audio && "${SOFTWARE_GPU_SELECTED:-true}" == false && "${VIRTUAL_AUDIO_SELECTED:-true}" == false ]]; then
  mkdir -p "test-results/acceptance-$task_suite"
  printf '%s\n' 'Qualified phase omission; see acceptance-selection-observation artifact' > "test-results/acceptance-$task_suite/selection.txt"
  exit 0
fi
: "${SDK_IMAGE:?Verified SDK required}"
python tools/ci_app_build_transport.py --repository "$GITHUB_REPOSITORY" --acceptance
task_repository=$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')
docker buildx build --builder "$(docker context show)" --platform linux/amd64 --load \
  --file packaging/acceptance.Dockerfile --target acceptance --build-arg "SDK_IMAGE=$SDK_IMAGE" \
  --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:acceptance-tools-buildcache-v1" \
  --cache-from "type=registry,ref=ghcr.io/$task_repository/linux-sdk:app-buildcache-x86-64" \
  --tag foresight-acceptance:local .
python tools/test_installed_release.py --prepare-models-only --models build/acceptance-models --output test-results/model-download
mkdir -p "test-results/acceptance-$task_suite"
chmod 0777 "test-results/acceptance-$task_suite"
task_common=(--rm --network none --cap-drop ALL --security-opt no-new-privileges
  -v "$PWD/build/acceptance-models:/models:ro"
  -v "$PWD/test-results/acceptance-$task_suite:/reports"
  -v "$PWD/build/portable/dist/open-foresight:/src/dist/open-foresight:ro")
if [[ "$task_suite" == cpu ]]; then
  docker run "${task_common[@]}" foresight-acceptance:local python3 tools/integration_gates.py \
    --suite models --bundle dist/open-foresight --models /models --output /reports
else
  task_status=0
  if [[ "${SOFTWARE_GPU_SELECTED:-true}" == true ]]; then
  docker run "${task_common[@]}" foresight-acceptance:local python3 tools/accept_software_gpu.py \
    --allow-litert-unavailable --bundle dist/open-foresight --models /models --output /reports/software-gpu || task_status=$?
  fi
  if [[ "${VIRTUAL_AUDIO_SELECTED:-true}" == true ]]; then
  docker run "${task_common[@]}" foresight-acceptance:local dbus-run-session -- python3 tools/integration_gates.py \
    --suite virtual-audio --bundle dist/open-foresight --models /models --output /reports/virtual-audio || task_status=$?
  fi
  exit "$task_status"
fi
