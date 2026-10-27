"""Linux stage independence and Ubuntu build sharing stay fail closed."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import sys

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
    for stage in ("core", "desktop", "service"):
        assert jobs[stage + "-linux"]["needs"] == ["native-linux"]
    assert "if" not in jobs["service-linux"], "A failed Native producer remains fatal"
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


@pytest.mark.parametrize("platform", ["linux"])
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


def test_ubuntu_package_and_acceptance_share_the_original_verified_application():
    jobs = workflow("macos.yml")["jobs"]
    producer = jobs["linux-build"]
    builds = [
        step["run"]
        for step in producer["steps"]
        if "tools/build_linux_container.sh" in step.get("run", "")
    ]
    assert len(builds) == 1
    assert "--build-only" in builds[0]
    assert "--test-only" not in builds[0]
    assert producer["outputs"]["bundle_id"] == "${{ steps.bundle.outputs.artifact-id }}"
    test = jobs["linux-test"]
    assert test["needs"] == "linux-build"
    test_commands = "\n".join(step.get("run", "") for step in test["steps"])
    assert "tools/ci_linux_handoff.py qualify" in test_commands
    assert "tools/build_linux_container.sh --test-only" in test_commands
    assert "--build-only" not in test_commands
    consumer_action = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-consumer/action.yml").read_text()
    )
    consumer_commands = "\n".join(
        step.get("run", "") for step in consumer_action["runs"]["steps"]
    )
    assert "tools.integration_application" in consumer_commands
    assert (
        '--artifact-id "$ARTIFACT_ID" --artifact-digest "$ARTIFACT_DIGEST"'
        in consumer_commands
    )
    assert '--attempt "$PRODUCER_ATTEMPT"' in consumer_commands
    assert "ci_linux_acceptance.py" in consumer_commands
    for phase in ("cpu", "audio", "deb"):
        job = jobs["acceptance-" + phase]
        assert job["needs"] == ["changes", "linux-build"]
        assert "!cancelled()" in job["if"]
        assert "needs.linux-build.result == 'success'" in job["if"]
        assert "linux-bundle" not in job["if"]
        setup = next(
            step
            for step in job["steps"]
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        for key, output in (
            ("artifact-id", "bundle_id"),
            ("artifact-digest", "bundle_digest"),
            ("attempt", "attempt"),
        ):
            assert (
                setup["with"][key] == "${{ needs.linux-build.outputs." + output + " }}"
            )
        assert "legacy-main" not in setup["with"]
        commands = "\n".join(step.get("run", "") for step in job["steps"])
        assert "bash tools/linux_acceptance.sh " + phase in commands
        assert "build_linux_container.sh" not in commands
        assert not any(
            step.get("with", {}).get("file") == "packaging/build.Dockerfile"
            for step in job["steps"]
        )
    assert jobs["acceptance-checks"]["if"] == "always()"
    assert set(jobs["acceptance-checks"]["needs"]) == {
        "changes",
        "linux-build",
        "acceptance-cpu",
        "acceptance-audio",
        "acceptance-deb",
    }
    assert "--max-glibc 2.39" in (ROOT / "tools/linux_container_build.sh").read_text()
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
    job = workflow("macos.yml")["jobs"]["acceptance-checks"]
    step = next(step for step in job["steps"] if "--check-gates" in step.get("run", ""))
    assert step["env"]["NEEDS"] == "${{ toJSON(needs) }}"
    assert step["env"]["SELECTED"] == "${{ needs.changes.outputs.linux_build }}"
    needs = {"changes": {"result": changes}}
    needs.update(
        {
            name: {"result": package}
            for name in (
                "linux-build",
                "acceptance-cpu",
                "acceptance-audio",
                "acceptance-deb",
            )
        }
    )
    result = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=ROOT,
        env={**os.environ, "SELECTED": selected, "NEEDS": json.dumps(needs)},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert (result.returncode == 0) == success, result.stdout + result.stderr


@pytest.mark.parametrize(
    "gate",
    [
        "linux-build",
        "acceptance-cpu",
        "acceptance-audio",
        "acceptance-deb",
    ],
)
@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped"])
def test_actual_acceptance_aggregate_requires_each_selected_consumer(gate, result):
    job = workflow("macos.yml")["jobs"]["acceptance-checks"]
    command = next(
        step["run"] for step in job["steps"] if "--check-gates" in step.get("run", "")
    )
    needs = {name: {"result": "success"} for name in job["needs"]}
    needs[gate]["result"] = result
    process = subprocess.run(
        ["bash", "-e", "-c", command],
        cwd=ROOT,
        env={**os.environ, "SELECTED": "true", "NEEDS": json.dumps(needs)},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert process.returncode != 0, process.stdout + process.stderr


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


@pytest.mark.parametrize("platform", ["linux"])
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


@pytest.mark.parametrize("platform", ["linux"])
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
            assert "--input core=" not in command
            assert "--input desktop=" not in command
            assert not any(
                step.get("with", {}).get("path")
                in {"build/ci-input/core", "build/ci-input/desktop"}
                for step in steps
            )
            assert jobs[f"service-{platform}"]["needs"] == [f"native-{platform}"]
            assert json.loads(
                next(step for step in steps if step.get("id") == "stage")["env"][
                    "STAGE_PARENTS"
                ]
            ) == {"native": "${{ needs.native-" + platform + ".outputs.identity }}"}


@pytest.mark.parametrize(
    "name",
    [
        "macos.yml",
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
    if name == "macos.yml":
        # The workflow invokes the shared consumer command rather than embedding
        # another installer implementation. Inspect the actual helper it runs.
        for phase in ("cpu", "audio", "deb"):
            assert any(
                "bash tools/linux_acceptance.sh " + phase in step.get("run", "")
                for step in workflow(name)["jobs"]["acceptance-" + phase]["steps"]
            )
        commands.extend(
            line
            for line in (ROOT / "tools/linux_acceptance.sh").read_text().splitlines()
            if "--security-opt seccomp=unconfined" in line
        )
    assert commands
    for command in commands:
        assert "--cap-add NET_ADMIN" in command
        assert "--security-opt systempaths=unconfined" in command
        assert "--cap-add SYS_ADMIN" not in command
        assert "--security-opt apparmor=foresight-ci-document-sandbox" in command
        assert "--privileged" not in command
    # This configures the disposable outer container; the real parser retains
    # its separate user/PID/network/mount namespaces and drops all capabilities.
    parser = (ROOT / "packages/foresight_core/lib/src/document_parser.dart").read_text()
    assert "'--unshare-all'" in parser
    assert "'--cap-drop',\n        'ALL'" in parser


def test_hosted_relocated_macos_smoke_checks_the_actual_checkout_revision():
    job = workflow("macos.yml")["jobs"]["macos"]
    step = next(
        step
        for step in job["steps"]
        if step.get("name")
        == "Relocated application MCP smoke with minimal environment"
    )
    assert "tools/smoke_macos_bundle.py" in step["run"]
    assert '--expected-revision "$(git rev-parse HEAD)"' in step["run"]
    assert "--output test-results/macos-bundle.json" in step["run"]


def test_optional_litert_gpu_policy_is_confined_to_ci_emulator_acceptance():
    job = workflow("macos.yml")["jobs"]["acceptance-audio"]
    assert any(
        step.get("run") == "bash tools/linux_acceptance.sh audio"
        for step in job["steps"]
    )
    command = (ROOT / "tools/linux_acceptance.sh").read_text()
    assert "tools/accept_software_gpu.py" in command
    assert "--allow-litert-unavailable" in command
    assert "--allow-unavailable" not in command
    assert "--suite virtual-audio" in command
    assert "|| task_status=$?" in command
    for name in ("release.yml", "release-acceptance.yml"):
        assert (
            "--allow-litert-unavailable"
            not in (ROOT / ".github/workflows" / name).read_text()
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
        ("push", "tree", "docs/unshipped.md", True),
        ("pull_request", "advanced-main", "docs/unshipped.md", False),
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
    shutil.copytree(
        ROOT / "tools",
        tools,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    fixture_bin = tmp_path / "bin"
    fixture_bin.mkdir()
    fixture_gh = fixture_bin / "gh"
    fixture_gh.write_text("#!/bin/sh\nprintf '%s\\n' '{\"artifacts\":[]}'\n")
    fixture_gh.chmod(0o755)
    workflow_dir = repository / ".github/workflows"
    workflow_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / ".github/workflows/native-sanitizers.yml",
        workflow_dir / "native-sanitizers.yml",
    )

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
    elif before == "tree":
        before = git("rev-parse", "HEAD^{tree}")
    elif before == "advanced-main":
        (repository / "main-only-native.cpp").write_text("unrelated main source")
        git("add", ".")
        git("commit", "-qm", "main advances independently")
        before = git("rev-parse", "HEAD")
        git("checkout", "-qb", "fixture-pr", base)
    elif before == "valid":
        before = base
    path = repository / changed
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("fixture change\n")
    git("add", ".")
    git("commit", "-qm", "current")
    command = next(
        step["run"]
        for step in workflow("macos.yml")["jobs"]["changes"]["steps"]
        if step.get("id") == "changes"
    )
    output = tmp_path / "output"
    result = subprocess.run(
        ["bash", "-e", "-c", command],
        cwd=repository,
        env={
            **os.environ,
            "PATH": str(fixture_bin) + os.pathsep + os.environ["PATH"],
            "GITHUB_REPOSITORY": "example/reviewed",
            "GITHUB_REF": "refs/heads/main"
            if event != "pull_request"
            else "refs/pull/123/merge",
            "GITHUB_EVENT_NAME": event,
            "GH_TOKEN": "fixture-read-only",
            "PR_NUMBER": "",
            "SWEEP": "false",
            "QUALIFICATION_MODE": "false",
            "BASE": before,
            "PUSH_BASE": before if event == "push" else "",
            "EVENT": event,
            "PLATFORMS": "all",
            "FORCE": "--force" if event in ("schedule", "workflow_dispatch") else "",
            "GITHUB_OUTPUT": str(output),
        },
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    values = dict(line.split("=", 1) for line in output.read_text().splitlines())
    assert "linux_bundle" not in values
    assert values["linux_build"] == str(selected).lower()


def test_package_and_acceptance_share_the_exact_inrun_build_without_compiling_again():
    jobs = workflow("macos.yml")["jobs"]
    for name in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        job = jobs[name]
        assert job["needs"] == ["changes", "linux-build"]
        assert "!cancelled()" in job["if"]
        assert "needs.linux-build.result == 'success'" in job["if"]
        setup = next(
            step
            for step in job["steps"]
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        assert "needs.linux-build.outputs.bundle_id" in setup["with"]["artifact-id"]
        assert (
            setup["with"]["artifact-id"] == "${{ needs.linux-build.outputs.bundle_id }}"
        )
        assert not any(
            step.get("with", {}).get("file") == "packaging/build.Dockerfile"
            for step in job["steps"]
        )
    assert (
        jobs["packaging"]["with"]["bundle_id"]
        == "${{ needs.linux-build.outputs.bundle_id }}"
    )
    assert "--max-glibc 2.39" in (ROOT / "tools/linux_container_build.sh").read_text()
    assert "pull_request" not in workflow("linux-packages.yml")["on"]


@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped"])
def test_failed_consolidated_macos_cannot_be_hidden_by_successful_packaging(result):
    from tools.ci_changes import check_gates, select_gates

    jobs = workflow("macos.yml")["jobs"]
    assert "macos" in jobs["platform-checks"]["needs"]
    selected = select_gates(["apps/desktop/macos/source.swift"])
    results = {
        "changes": {"result": "success"},
        **{
            name: {"result": "success" if needed else "skipped"}
            for name, needed in selected.items()
        },
    }
    results["macos"] = {"result": result}
    results["linux-native"] = {"result": "skipped"}
    with pytest.raises(ValueError, match="macos: expected success"):
        check_gates(results, selected)


def test_debian_compatibility_remains_independent_of_buildkit_fixture_failure():
    jobs = workflow("macos.yml")["jobs"]
    assert any(
        "pytest tests/test_acceptance_image_cache.py" in step.get("run", "")
        for step in jobs["linux-test"]["steps"]
    )
    debian = jobs["acceptance-deb"]
    assert "linux-test" not in debian["needs"]
    assert debian["needs"] == ["changes", "linux-build"]
    assert "!cancelled()" in debian["if"]
    assert "needs.linux-build.result == 'success'" in debian["if"]
    assert any(
        step.get("run") == "bash tools/linux_acceptance.sh deb"
        for step in debian["steps"]
    )
    shared = (ROOT / "tools/linux_acceptance.sh").read_text()
    assert "--security-opt apparmor=foresight-ci-document-sandbox" in shared
    assert "dist/packages:/packages:ro" in shared
    assert "debian:13@sha256:" in shared


@pytest.mark.parametrize(
    "cached,pull_fails", [(True, False), (False, False), (False, True)]
)
def test_shadow_host_prepares_pinned_base_before_offline_cache_fixture(
    tmp_path, cached, pull_fails
):
    steps = workflow("macos.yml")["jobs"]["linux-test"]["steps"]
    fixture = next(
        step
        for step in steps
        if step.get("name") == "Run the real Docker cache fixture on the host"
    )
    base = fixture["env"]["CACHE_FIXTURE_BASE"]
    assert (
        f'BASE = "{base}"'
        in (ROOT / "tests/test_acceptance_image_cache.py").read_text()
    )
    executable = tmp_path / "bin"
    executable.mkdir()
    trace = tmp_path / "commands.jsonl"
    tool = executable / "tool"
    tool.write_text(
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys\n"
        "name = pathlib.Path(sys.argv[0]).name\n"
        "with open(os.environ['FIXTURE_TRACE'], 'a') as log:\n"
        "    log.write(json.dumps([name, *sys.argv[1:]]) + '\\n')\n"
        "if name == 'docker':\n"
        "    if sys.argv[1:3] == ['image', 'inspect']:\n"
        "        sys.exit(0 if os.environ['FIXTURE_CACHED'] == '1' else 1)\n"
        "    if sys.argv[1] == 'pull':\n"
        "        sys.exit(1 if os.environ['FIXTURE_PULL_FAILS'] == '1' else 0)\n"
        "    sys.exit(99)\n"
        "assert os.environ['FORESIGHT_DOCKER_CACHE_TEST'] == '1'\n"
    )
    tool.chmod(0o755)
    for name in ("docker", "python"):
        (executable / name).symlink_to(tool)
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"BASH_ENV", "ENV"}
    }
    env.update(
        fixture["env"],
        PATH=str(executable) + os.pathsep + env["PATH"],
        FIXTURE_TRACE=str(trace),
        FIXTURE_CACHED=str(int(cached)),
        FIXTURE_PULL_FAILS=str(int(pull_fails)),
    )
    result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-e",
            "-o",
            "pipefail",
            "-c",
            fixture["run"],
        ],
        env=env,
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=30,
    )
    commands = [json.loads(line) for line in trace.read_text().splitlines()]
    expected = [["docker", "image", "inspect", base]]
    if not cached:
        expected.append(["docker", "pull", base])
    if cached or not pull_fails:
        expected.append(
            ["python", "-m", "pytest", "tests/test_acceptance_image_cache.py", "-ra"]
        )
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, result.stdout + result.stderr
    assert commands == expected


def test_service_setup_contains_the_core_source_build_prerequisites():
    steps = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-stage/action.yml").read_text()
    )["runs"]["steps"]
    named = {step.get("name"): step for step in steps}
    packages = named["Install Linux application toolchain"]
    assert "if" not in packages
    assert {"cmake", "ninja", "gcc", "python", "python-pip", "uv", "pkgconf"} <= set(
        packages["run"].split()
    )
    python = named["Install locked Python development dependencies"]
    assert "if" not in python
    assert "--require-hashes -r requirements-dev.lock" in python["run"]
    for name in (
        "Verify the pinned Linux Flutter SDK",
        "Resolve locked language prerequisites for isolated stages",
    ):
        assert named[name]["if"] == "inputs.stage != 'native'"
    assert (
        "dart pub get --enforce-lockfile"
        in named["Resolve locked language prerequisites for isolated stages"]["run"]
    )
    assert (
        named["Warm the pinned desktop engine cache"]["if"]
        == "inputs.stage == 'desktop' || inputs.stage == 'service'"
    )


def test_parent_aggregate_keeps_all_independent_linux_stages_required():
    parent = workflow("macos.yml")["jobs"]
    assert (
        parent["linux-native"]["uses"]
        == "./.github/workflows/linux-platform-stages.yml"
    )
    assert "linux-native" in parent["platform-checks"]["needs"]
    assert parent["platform-checks"]["if"] == "always()"
    jobs = workflow("linux-platform-stages.yml")["jobs"]
    assert set(jobs) == {f"{stage}-linux" for stage in STAGES}
    assert not any(job.get("continue-on-error") for job in jobs.values())
