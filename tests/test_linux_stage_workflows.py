"""Linux stage independence and Ubuntu build sharing stay fail closed."""

import json
import os
from pathlib import Path
import subprocess
import shutil

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
            if parent == "desktop":
                assert f"--input {parent}=" not in command
                continue
            assert f"--input {parent}=build/ci-input/{parent}" in command
            download = next(
                step
                for step in job["steps"]
                if step.get("with", {}).get("path") == f"build/ci-input/{parent}"
            )
            assert (
                download["with"]["name"]
                == "${{ needs."
                + parent_job
                + ".outputs."
                + ("runtime_artifact_name" if parent == "native" else "artifact_name")
                + " }}"
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


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_native_work_receipt_is_uploaded_separately_from_full_payload(platform):
    job = workflow(f"{platform}-platform-stages.yml")["jobs"][f"native-{platform}"]
    uploads = [
        step
        for step in job["steps"]
        if step.get("uses", "").startswith("actions/upload-artifact@")
    ]
    full = next(
        step
        for step in uploads
        if step["with"]["name"] == "${{ steps.stage.outputs.artifact_name }}"
    )
    receipt = next(
        step
        for step in uploads
        if step["with"]["name"] == "receipt-${{ steps.stage.outputs.artifact_name }}"
    )
    assert receipt["with"]["path"] == f"build/ci-stage/{platform}-native/identity.json"
    assert "payload.tar.gz" not in receipt["with"]["path"]
    assert receipt["with"]["retention-days"] == full["with"]["retention-days"]
    assert receipt["with"]["if-no-files-found"] == "error"
    assert receipt["with"]["overwrite"] is True


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
    assert builds[0]["with"]["target"] == "builder"
    assert builds[0]["if"] == "github.event_name == 'pull_request'"
    assert builds[0]["with"]["load"] is True
    assert (
        "SOURCE_REVISION=${{ github.event.pull_request.head.sha || github.sha }}"
        in builds[0]["with"]["build-args"]
    )
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "docker create foresight-built-application:local /bin/true" in commands
    assert (
        'docker cp "$task_container:/src/dist/open-foresight" build/portable/dist/'
        in commands
    )
    package_step = next(
        step
        for step in job["steps"]
        if "package-and-test.sh deb" in step.get("run", "")
    )
    assert "--security-opt seccomp=unconfined" in package_step["run"]
    assert "--security-opt systempaths=unconfined" in package_step["run"]
    assert (
        "--security-opt apparmor=foresight-ci-document-sandbox" in package_step["run"]
    )
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
        timeout=30,
    )
    assert (result.returncode == 0) == success


@pytest.mark.parametrize(
    "changed,expected",
    [
        ("native/worker.cpp", set(STAGES)),
        ("packages/foresight_core/lib/app.dart", {"core", "desktop", "service"}),
        ("apps/desktop/lib/main.dart", {"core", "desktop", "service"}),
        ("packaging/build.Dockerfile", set(STAGES)),
        ("docs/guide.md", set()),
        ("new-unclassified-build-input.xyz", set(STAGES)),
    ],
)
def test_complete_stage_inputs_and_parent_identities_invalidate_expected_stages(
    tmp_path, changed, expected
):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=30)
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


@pytest.mark.parametrize("failed", ["native", "core", "desktop", "service"])
def test_failed_macos_stage_cannot_be_hidden_by_successful_packaging(failed):
    from tools.ci_changes import check_gates, select_gates

    jobs = workflow("macos.yml")["jobs"]
    assert "needs.macos-stages.result == 'success'" in jobs["macos"]["if"]
    assert "macos-stages" in jobs["platform-checks"]["needs"]
    reusable = workflow("macos-platform-stages.yml")["jobs"]
    assert f"{failed}-macos" in reusable
    selected = select_gates(["apps/desktop/macos/source.swift"])
    # A failed reusable child makes its caller fail even when installer artifacts
    # from other children exist and packaging could otherwise finish successfully.
    results = {
        "changes": {"result": "success"},
        **{
            name: {"result": "success" if value else "skipped"}
            for name, value in selected.items()
        },
        "macos-stages": {"result": "failure"},
    }
    with pytest.raises(ValueError, match="macos-stages"):
        check_gates(results, selected, False)


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_stage_artifact_uploads_allow_reruns_and_do_not_recompress_gzip(platform):
    jobs = workflow(f"{platform}-platform-stages.yml")["jobs"]
    for job in jobs.values():
        uploads = [
            step["with"]
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact@")
        ]
        assert uploads
        for upload in uploads:
            assert upload["overwrite"] is True
            if "payload.tar.gz" in upload["path"]:
                assert upload["compression-level"] == 0


def test_container_git_access_is_configured_for_foreign_owned_checkout(tmp_path):
    repository = tmp_path / "checkout"
    subprocess.run(["git", "init", "-q", str(repository)], check=True, timeout=30)
    environment = {
        **os.environ,
        "GITHUB_WORKSPACE": str(repository),
        "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(tmp_path / "gitconfig"),
    }
    denied = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=repository,
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert denied.returncode != 0 and "dubious ownership" in denied.stderr
    setup = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-stage/action.yml").read_text()
    )
    step = next(
        step
        for step in setup["runs"]["steps"]
        if "safe.directory" in step.get("run", "")
    )
    accepted = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=repository,
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert accepted.returncode == 0, accepted.stderr
    assert accepted.stdout.strip() == str(repository)
    assert "*" not in (tmp_path / "gitconfig").read_text()


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_language_jobs_download_only_slim_native_runtime_and_service_omits_unused_release_bundle(
    platform,
):
    jobs = workflow(f"{platform}-platform-stages.yml")["jobs"]
    for stage in ("core", "desktop", "service"):
        steps = jobs[f"{stage}-{platform}"]["steps"]
        native = next(
            step
            for step in steps
            if step.get("with", {}).get("path") == "build/ci-input/native"
        )
        assert (
            native["with"]["name"]
            == "${{ needs.native-" + platform + ".outputs.runtime_artifact_name }}"
        )
        command = next(step["run"] for step in steps if step.get("id") == "stage")
        assert "--input native=build/ci-input/native" in command
        if stage == "service":
            assert "--input core=build/ci-input/core" in command
            assert "--input desktop=" not in command
            assert not any(
                step.get("with", {}).get("path") == "build/ci-input/desktop"
                for step in steps
            )
            assert f"desktop-{platform}" in jobs[f"service-{platform}"]["needs"]
            assert "desktop" in json.loads(
                next(step for step in steps if step.get("id") == "stage")["env"][
                    "STAGE_PARENTS"
                ]
            )


@pytest.mark.parametrize(
    "name",
    [
        "integration-acceptance.yml",
        "linux-packages.yml",
        "preview-packages.yml",
        "release-acceptance.yml",
    ],
)
def test_disposable_installed_document_containers_can_initialize_isolated_loopback(
    name,
):
    commands = [
        step["run"]
        for job in workflow(name)["jobs"].values()
        for step in job.get("steps", [])
        if "--security-opt seccomp=unconfined" in step.get("run", "")
    ]
    assert commands
    for command in commands:
        assert "--cap-add NET_ADMIN" in command
        assert "--security-opt systempaths=unconfined" in command
        assert "--cap-add SYS_ADMIN" not in command
        assert "--security-opt apparmor=foresight-ci-document-sandbox" in command
        assert "--privileged" not in command
    # This configures the disposable outer container; the real parser retains
    # its separate user/PID/network/mount namespaces and drops all capabilities.
    parser = (ROOT / "packages/foresight_core/lib/src/store.dart").read_text()
    assert "'--unshare-all'" in parser
    assert "'--cap-drop',\n        'ALL'" in parser


def test_hosted_relocated_macos_smoke_checks_the_actual_checkout_revision():
    job = workflow("macos.yml")["jobs"]["macos"]
    step = next(
        step for step in job["steps"]
        if step.get("name") == "Relocated application MCP smoke with minimal environment"
    )
    assert "tools/smoke_macos_bundle.py" in step["run"]
    assert '--expected-revision "$(git rev-parse HEAD)"' in step["run"]
    assert "--output test-results/macos-bundle.json" in step["run"]


def test_optional_litert_gpu_policy_is_confined_to_ci_emulator_acceptance():
    jobs = workflow("integration-acceptance.yml")["jobs"]
    step = next(
        step
        for step in jobs["ubuntu-package"]["steps"]
        if step.get("name") == "Shipped GPU runtimes on software Vulkan"
    )
    assert "--allow-litert-unavailable" in step["run"]
    assert "--allow-unavailable" not in step["run"]
    for name in ("release.yml", "release-acceptance.yml"):
        assert (
            "--allow-litert-unavailable" not in (ROOT / ".github/workflows" / name).read_text()
        )


@pytest.mark.parametrize(
    ("event", "before", "changed", "selected"),
    [
        ("push", "valid", "docs/unshipped.md", False),
        ("push", "valid", "packaging/notices/nlohmann-json.md", True),
        ("push", "valid", "native/new.cpp", True),
        ("push", "", "docs/unshipped.md", True),
        ("push", "0" * 40, "docs/unshipped.md", True),
        ("push", "1" * 40, "docs/unshipped.md", True),
        ("push", "HEAD~1", "docs/unshipped.md", True),
        ("push", "unrelated", "docs/unshipped.md", True),
        ("workflow_dispatch", "valid", "docs/unshipped.md", True),
        ("schedule", "valid", "docs/unshipped.md", True),
        ("pull_request", "valid", "docs/unshipped.md", False),
    ],
)
def test_actual_acceptance_selection_uses_main_push_range_and_fails_safe(
    tmp_path, event, before, changed, selected
):
    repository = tmp_path / "repository"
    repository.mkdir()
    tools = repository / "tools"
    tools.mkdir()
    shutil.copy2(ROOT / "tools/ci_changes.py", tools / "ci_changes.py")

    def git(*arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=repository, text=True, timeout=30
        ).strip()

    git("init", "-q")
    git("config", "user.name", "CI fixture")
    git("config", "user.email", "ci@example.invalid")
    git("add", ".")
    git("commit", "-qm", "baseline")
    base = git("rev-parse", "HEAD")
    if before == "unrelated":
        tree = git("rev-parse", "HEAD^{tree}")
        before = git("commit-tree", tree, "-m", "unrelated history")
    elif before == "valid":
        before = base
    path = repository / changed
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("fixture change\n")
    git("add", ".")
    git("commit", "-qm", "current")
    command = next(
        step["run"]
        for step in workflow("integration-acceptance.yml")["jobs"]["changes"]["steps"]
        if step.get("id") == "select"
    )
    output = tmp_path / "output"
    subprocess.run(
        ["bash", "-e", "-c", command],
        cwd=repository,
        env={
            **os.environ,
            "BASE": before,
            "EVENT": event,
            "GITHUB_OUTPUT": str(output),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    values = dict(line.split("=", 1) for line in output.read_text().splitlines())
    assert values["linux_bundle"] == str(selected).lower()
