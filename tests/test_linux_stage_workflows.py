"""Linux stage independence and Ubuntu build sharing stay fail closed."""

import json
import os
from pathlib import Path
import subprocess

import pytest
import yaml

from tools.ci_stage_cache import STAGES, fingerprint

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    result = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
    # PyYAML's YAML 1.1 resolver treats the Actions key "on" as a boolean.
    if True in result:
        result["on"] = result.pop(True)
    return result


def test_linux_native_core_desktop_and_service_are_independent_jobs():
    jobs = workflow("linux-platform-stages.yml")["jobs"]
    assert set(jobs) == {stage + "-linux" for stage in STAGES}
    assert "needs" not in jobs["native-linux"]
    for stage in ("core", "desktop"):
        assert jobs[stage + "-linux"]["needs"] == ["native-linux"]
    assert jobs["service-linux"]["needs"] == [
        "native-linux",
        "core-linux",
        "desktop-linux",
    ]
    for stage in STAGES:
        job = jobs[stage + "-linux"]
        assert job["name"] == stage + "-linux"
        assert job["container"].startswith("archlinux:base-devel@sha256:")
        assert job["runs-on"] == "ubuntu-24.04"
        assert any(
            step.get("uses") == "./.github/actions/setup-linux-stage"
            for step in job["steps"]
        )
        checkout = next(
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/checkout@")
        )
        assert checkout["with"]["ref"] == "${{ inputs.source }}"
        stage_step = next(step for step in job["steps"] if step.get("id") == "stage")
        command = stage_step["run"]
        assert "tools/run_ci_stage.py" in command
        assert f"--platform linux --stage {stage}" in command
        assert '--event "$STAGE_EVENT" --own-pr "$OWN_PR"' in command
        assert '--parents-json "$STAGE_PARENTS"' in command
        assert "args+=(--release)" in command
        parents = json.loads(stage_step["env"]["STAGE_PARENTS"])
        for parent_job in job.get("needs", []):
            parent = parent_job.removesuffix("-linux")
            assert parents[parent] == "${{ needs." + parent_job + ".outputs.identity }}"
            assert f"--input {parent}=build/ci-input/{parent}" in command
            download = next(
                step
                for step in job["steps"]
                if step.get("with", {}).get("path") == f"build/ci-input/{parent}"
            )
            assert (
                download["with"]["name"]
                == "${{ needs." + parent_job + ".outputs.artifact_name }}"
            )
        upload = next(
            step
            for step in job["steps"]
            if step.get("with", {}).get("name")
            == "${{ steps.stage.outputs.artifact_name }}"
        )
        assert upload["with"]["if-no-files-found"] == "error"
        assert f"build/ci-stage/linux-{stage}/identity.json" in upload["with"]["path"]
        assert f"build/ci-stage/linux-{stage}/payload.tar.gz" in upload["with"]["path"]
        assert not any(step.get("continue-on-error") is True for step in job["steps"])


def test_linux_setup_records_packages_and_keeps_flutter_pin():
    action = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-stage/action.yml").read_text()
    )
    commands = "\n".join(step.get("run", "") for step in action["runs"]["steps"])
    assert "--require-hashes -r requirements-dev.lock" in commands
    assert "adc901062556672b4138e18a4dc62a4be8f4b3c2" in commands
    assert "ci_stage_environment.py --platform linux" in commands
    assert "github-cli" in commands


def test_ubuntu_package_and_acceptance_use_one_exact_application_build():
    jobs = workflow("integration-acceptance.yml")["jobs"]
    assert jobs["acceptance-checks"]["if"] == "always()"
    assert jobs["acceptance-checks"]["needs"] == ["changes", "ubuntu-package"]
    aggregate = jobs["acceptance-checks"]["steps"][0]
    assert aggregate["env"]["LINUX_RESULT"] == "${{ needs.ubuntu-package.result }}"
    assert 'test "$LINUX_RESULT" = success' in aggregate["run"]
    assert 'test "$LINUX_RESULT" = skipped' in aggregate["run"]
    job = jobs["ubuntu-package"]
    builds = [
        step
        for step in job["steps"]
        if step.get("with", {}).get("file") == "packaging/build.Dockerfile"
    ]
    assert len(builds) == 1
    assert builds[0]["with"]["target"] == "integration"
    assert builds[0]["with"]["load"] is True
    assert (
        "SOURCE_REVISION=${{ github.event.pull_request.head.sha || github.sha }}"
        in builds[0]["with"]["build-args"]
    )
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "docker create foresight-integration:local /bin/true" in commands
    assert (
        'docker cp "$task_container:/src/dist/open-foresight" build/portable/dist/'
        in commands
    )
    assert "package-and-test.sh deb" in commands
    assert "--suite models" in commands and "--suite virtual-audio" in commands
    assert "--max-glibc 2.39" in (ROOT / "packaging/build.Dockerfile").read_text()
    assert "pull_request" not in workflow("linux-packages.yml")["on"]
    assert "workflow_call" in workflow("linux-packages.yml")["on"]


@pytest.mark.parametrize(
    "changes,selected,package,success",
    [
        ("success", "true", "success", True),
        ("success", "true", "failure", False),
        ("success", "true", "cancelled", False),
        ("success", "true", "skipped", False),
        ("success", "false", "skipped", True),
        ("success", "false", "success", False),
        ("success", "invalid", "skipped", False),
        ("failure", "false", "skipped", False),
    ],
)
def test_acceptance_aggregate_rejects_every_incomplete_selected_job(
    changes, selected, package, success
):
    job = workflow("integration-acceptance.yml")["jobs"]["acceptance-checks"]
    result = subprocess.run(
        ["bash", "-e", "-c", job["steps"][0]["run"]],
        env={
            **os.environ,
            "CHANGES_RESULT": changes,
            "SELECTED": selected,
            "LINUX_RESULT": package,
        },
        check=False,
    )
    assert (result.returncode == 0) == success


def test_main_schedule_and_manual_acceptance_force_validation():
    selection = workflow("integration-acceptance.yml")["jobs"]["changes"]["steps"][-1]
    assert (
        'if [[ "$EVENT" != pull_request ]]; then args+=(--force); fi'
        in selection["run"]
    )


@pytest.mark.parametrize(
    "changed,expected",
    [
        ("native/worker.cpp", set(STAGES)),
        ("packages/foresight_core/lib/app.dart", {"core", "desktop", "service"}),
        ("apps/desktop/lib/main.dart", {"desktop", "service"}),
        ("packaging/build.Dockerfile", set(STAGES)),
        ("docs/guide.md", set()),
        ("new-unclassified-build-input.xyz", set(STAGES)),
    ],
)
def test_complete_stage_inputs_and_parent_identities_invalidate_expected_stages(
    tmp_path, changed, expected
):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    environment = {
        "compiler": "gcc",
        "runtime": "Dart",
        "system": "Arch",
        "sdk": "pinned",
    }

    def keys():
        result = {}
        for stage in STAGES:
            parents = {} if stage == "native" else {"native": result["native"]}
            if stage == "service":
                parents.update(core=result["core"], desktop=result["desktop"])
            result[stage] = fingerprint(
                "linux", stage, tmp_path, environment=environment, parents=parents
            )
        return result

    before = keys()
    path = tmp_path / changed
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("new input")
    after = keys()
    assert {stage for stage in STAGES if before[stage] != after[stage]} == expected
