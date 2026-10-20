"""Shadow Ubuntu jobs cannot replace required checks or publish trusted caches."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_shadow_jobs_reuse_verified_inputs_and_leave_required_old_tier_intact():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    required = jobs["platform-checks"]["needs"]
    assert set(required) == {
        "changes",
        "workflow-lint",
        "macos",
        "macos-stages",
        "linux-native",
        "linux-document-imports",
        "linux-bundle",
        "packaging",
    }
    for name in ("linux-build", "linux-test", "linux-shadow-comparison"):
        assert name not in required
        assert jobs[name]["continue-on-error"] is True
    for name in ("linux-build", "linux-test"):
        assert jobs[name]["permissions"] == {
            "contents": "read",
            "actions": "read",
            "packages": "read",
        }
        text = str(jobs[name])
        assert "cache-to" not in text
        if name == "linux-test":
            assert "--run-id" in text
            assert "--artifact-id" in text
            assert "--artifact-digest" in text
            assert "--discard-archive" in text
    assert jobs["linux-test"]["needs"] == "linux-build"
    build = jobs["linux-build"]["steps"]
    test = jobs["linux-test"]["steps"]
    host_pack = next(step for step in build if step.get("id") == "receipt")
    assert "ci_artifacts.py pack --component linux-app" in host_pack["run"]
    assert '--tier "$CI_TIER" --label "$BUILD_LABEL"' in host_pack["run"]
    assert any("ci_linux_shadow_sdk.py" in step.get("run", "") for step in build)
    assert "build_linux_sdk_local.sh" not in str(build)
    sdk_upload = next(step for step in build if step.get("id") == "fork-sdk")
    assert sdk_upload["with"]["name"].startswith("shadow-sdk-")
    qualify = next(
        step for step in test if "ci_linux_handoff.py qualify" in step.get("run", "")
    )
    assert '"$ARTIFACT_ID"' in qualify["run"]
    assert (
        qualify["env"]["PRODUCER_ATTEMPT"] == "${{ needs.linux-build.outputs.attempt }}"
    )
    execute = next(
        step for step in test if "--test-only --output" in step.get("run", "")
    )
    assert (
        execute["env"]["FORESIGHT_CONTAINER_APPARMOR"]
        == "foresight-ci-document-sandbox"
    )
    assert any(
        step.get("env", {}).get("FORESIGHT_DOCKER_CACHE_TEST") == "1" for step in test
    )


def test_local_and_ci_container_paths_keep_secrets_out_of_layers_and_exact_packaging_flags():
    wrapper = (ROOT / "tools/build_linux_container.sh").read_text()
    shared = (ROOT / "tools/linux_container_build.sh").read_text()
    test = (ROOT / "tools/linux_container_test.sh").read_text()
    dockerfile = (ROOT / "packaging/build.Dockerfile").read_text()
    assert "/workspace/tools/linux_container_build.sh" in wrapper
    assert "/workspace/tools/linux_container_test.sh" in wrapper
    assert "--cache-from" in wrapper
    assert "--cache-to" not in wrapper
    assert '--build-context "appdeps_seed=$task_seed"' in wrapper
    assert "FROM application-dependencies AS ci" in dockerfile
    assert "FORESIGHT_PYTHON=/opt/dev-python/bin/python" in dockerfile
    for package in ("xvfb", "xauth", "dbus", "mesa", "poppler", "unrtf", "gh"):
        assert package in dockerfile
    assert (
        'bash tools/build.sh --build-only "-DFORESIGHT_BUILD_REVISION=$SOURCE_REVISION"'
        in shared
    )
    assert '--revision "$SOURCE_REVISION"' in shared
    assert "--require-google-client" in shared
    assert "/run/secrets/google_client" in shared
    assert "/run/secrets/foresight_search_api_key" in shared
    assert "/run/secrets/foresight_web_content_api_key" in shared
    assert (
        "--generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli"
        in shared
    )
    assert "--report dist/abi.json" in shared
    assert "ci_linux_handoff.py restore" in test
    assert "tools/build.sh --test-only" in test
    assert "tar -C /workspace" not in test
    assert "PUB_CACHE=/src/.pub-cache" in wrapper
    assert "copy_linux_source.sh /workspace /src" in shared
    assert "FORESIGHT_CORE_COVERAGE_MIN=90" in test
    assert "Compiled service suite must have zero skips" in test


def test_shadow_rollout_does_not_delay_or_fail_nightly_preview():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    selected = jobs["linux-build"]["if"]
    assert "github.event_name == 'pull_request'" in selected
    assert "!inputs.preview" in selected
    # The called preview has event=schedule or workflow_dispatch and preview=true.
    # Skipping the producer skips both downstream shadow jobs; legacy build stays unchanged.
    assert jobs["linux-test"]["needs"] == "linux-build"
    assert jobs["linux-shadow-comparison"]["needs"] == ["linux-native", "linux-test"]
    for name in ("linux-build", "linux-test", "linux-shadow-comparison"):
        assert jobs[name]["continue-on-error"] is True


def test_shadow_consumers_override_skipped_main_only_ancestors():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    # distribution-number is skipped on PRs. GitHub's implicit success() also
    # considers skipped ancestors, even after linux-build explicitly ran and
    # succeeded. Both downstream jobs must override that implicit status check.
    assert jobs["linux-test"]["if"] == (
        "!cancelled() && needs.linux-build.result == 'success' && "
        "needs.linux-build.outputs.complete == 'true' && "
        "needs.linux-build.outputs.handoff_id != ''"
    )
    assert jobs["linux-shadow-comparison"]["if"] == (
        "!cancelled() && needs.linux-native.result == 'success' && "
        "needs.linux-test.result == 'success' && "
        "needs.linux-test.outputs.complete == 'true'"
    )
    # Probationary continue-on-error jobs can appear successful in needs even
    # after a failed step. Only a normally reached final step marks their work
    # complete; artifact qualification still verifies the actual API job result.
    for name in ("linux-build", "linux-test"):
        assert jobs[name]["outputs"]["complete"] == (
            "${{ steps.complete.outputs.complete }}"
        )
        marker = jobs[name]["steps"][-1]
        assert marker["id"] == "complete"
        assert "if" not in marker  # Default success(), never an always() marker.
        assert marker["run"] == "echo 'complete=true' >> \"$GITHUB_OUTPUT\""
