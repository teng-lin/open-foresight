"""Retained application recovery preserves producer identity and original bytes."""

import hashlib
import io
import json
import shutil
import subprocess
import tarfile
import zipfile

import pytest
import yaml

from tools import ci_acceptance_application as recovery

SOURCE = "a" * 40
HEAD = "b" * 40
REPO = "owner/repo"
START = "2026-10-19T06:00:00Z"
CREATED = "2026-10-19T06:01:00Z"
END = "2026-10-19T06:02:00Z"


@pytest.fixture
def retained(tmp_path, monkeypatch):
    bundle = tmp_path / "original/open-foresight"
    files = {
        "app/open-foresight": b"\x7fELF" + b"\0" * 14 + b"\x3e\0",
        "bin/ForesightHelper": b"\x7fELF" + b"\0" * 14 + b"\x3e\0",
        "lib/libforesight_native.so": b"\x7fELF" + b"\0" * 14 + b"\x3e\0",
        "open-foresight": ("#!/bin/sh\n# original source " + SOURCE).encode(),
    }
    for name, content in files.items():
        path = bundle / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(0o755)
    manifest = {
        "revision": SOURCE,
        "version": "0.1.2",
        "build_number": 10,
        "files": [
            {"path": name, "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in files.items()
        ],
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest))
    payload = tmp_path / "application.tar.gz"
    with tarfile.open(payload, "w:gz") as tar:
        tar.add(bundle, arcname="open-foresight")
    receipt = {
        "revision": SOURCE,
        "version": "0.1.2",
        "build_number": 10,
        "format": "tar",
        "source_date_epoch": 123456789,
        "sha256": recovery.artifacts.digest(payload),
    }
    archive = tmp_path / "retained.zip"

    def write_zip():
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.write(payload, payload.name)
            zipped.writestr(
                payload.name + ".sha256", f"{receipt['sha256']}  {payload.name}\n"
            )
            zipped.writestr(payload.name + ".build.json", json.dumps(receipt))
            zipped.writestr(
                "abi.json",
                json.dumps(
                    {
                        "passed": True,
                        "failures": [],
                        "max_glibc": "2.39",
                        "max_glibcxx": "3.4.33",
                    }
                ),
            )

    write_zip()
    artifact = {
        "id": 17,
        "name": f"ubuntu-acceptance-application-{SOURCE}-1",
        "digest": "sha256:" + recovery.artifacts.digest(archive),
        "expired": False,
        "workflow_run": {"id": 42},
        "created_at": CREATED,
    }
    run = {
        "id": 42,
        "node_id": "WFR_fixture42",
        "head_sha": SOURCE,
        "run_attempt": 2,
        "path": recovery.WORKFLOW,
        "event": "pull_request",
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        "pull_requests": [
            {"number": 131, "head": {"sha": SOURCE}, "base": {"sha": "c" * 40}}
        ],
    }
    job = {
        "id": 99,
        "run_id": 42,
        "run_attempt": 1,
        "head_sha": SOURCE,
        "name": "ubuntu-package",
        "status": "completed",
        "conclusion": "failure",
        "started_at": START,
        "completed_at": END,
        "steps": [
            {
                "name": name,
                "conclusion": "success",
                "started_at": START,
                "completed_at": END,
            }
            for name in recovery.PRODUCER_STEPS
        ]
        + [
            {
                "name": "Prepare acceptance tools without application compilation",
                "conclusion": "failure",
            }
        ],
    }
    pull = {
        "created_at": START,
        "head": {"sha": HEAD, "ref": "fix/review", "repo": {"full_name": REPO}},
        "base": {"ref": "main", "repo": {"full_name": REPO}},
    }
    comparison = {"status": "ahead"}

    def api(repository, route):
        assert repository == REPO
        if route == "pulls/131":
            return pull
        if route.startswith("actions/workflows/"):
            assert "branch=fix%2Freview" in route
            return {"workflow_runs": [run]}
        if route == "actions/runs/42/artifacts?per_page=100&page=1":
            return {"artifacts": [artifact]}
        if route == f"compare/{'c' * 40}...{SOURCE}":
            return {"status": "ahead"}
        if route == f"compare/{SOURCE}...{HEAD}":
            return comparison
        if route == "actions/runs/42/attempts/1/jobs?per_page=100&page=1":
            return {"jobs": [job]}
        raise AssertionError(route)

    original_run = subprocess.run

    def command(args, **kwargs):
        if args[:3] == ["gh", "api", "graphql"]:
            assert "id=WFR_fixture42" in args
            record = run.get(
                "_workflow_record",
                {
                    "data": {
                        "node": {
                            "databaseId": 42,
                            "file": {
                                "repositoryName": REPO,
                                "path": recovery.WORKFLOW,
                                "repositoryFileUrl": f"https://github.com/{REPO}/blob/{SOURCE}/{recovery.WORKFLOW}",
                            },
                        }
                    }
                },
            )
            return subprocess.CompletedProcess(
                args, 0, stdout=json.dumps(record).encode()
            )
        if args[0] == "gh":
            assert args == ["gh", "api", f"repos/{REPO}/actions/artifacts/17/zip"]
            with archive.open("rb") as stream:
                shutil.copyfileobj(stream, kwargs["stdout"])
            return subprocess.CompletedProcess(args, 0)
        return original_run(args, **kwargs)

    monkeypatch.setattr(recovery.artifacts, "api", api)
    monkeypatch.setattr(recovery.artifacts.subprocess, "run", command)
    monkeypatch.setattr(recovery, "compatible", lambda *args: True)
    monkeypatch.setattr(
        recovery,
        "main_history",
        lambda *args: {
            "main_history_tip": "c" * 40,
            "main_history_merge_base": "c" * 40,
        },
    )
    return artifact, run, job, pull, comparison, receipt, archive, write_zip


def retrieve(tmp_path):
    return recovery.retrieve(
        REPO,
        HEAD,
        131,
        "fix/review",
        tmp_path / "packages",
        tmp_path / "restored/open-foresight",
        HEAD,
    )


def test_later_infrastructure_failure_reuses_successful_original_build(
    tmp_path, retained
):
    values = retrieve(tmp_path)
    assert values == {
        "hit": "true",
        "source": SOURCE,
        "producer_run": "42",
        "producer_attempt": "1",
        "artifact_id": "17",
        "artifact_digest": retained[0]["digest"],
        "producer_workflow_head": SOURCE,
        "consumer_workflow_source": HEAD,
        "producer_workflow_control_proof": "head-plus-protected-main-history",
        "main_history_tip": "c" * 40,
        "main_history_merge_base": "c" * 40,
        "version": "0.1.2",
        "epoch": "123456789",
    }
    assert (
        json.loads((tmp_path / "restored/open-foresight/manifest.json").read_text())[
            "revision"
        ]
        == SOURCE
    )
    assert (tmp_path / "packages/application.tar.gz").read_bytes() == (
        tmp_path / "application.tar.gz"
    ).read_bytes()
    assert SOURCE in (tmp_path / "restored/open-foresight/open-foresight").read_text()


@pytest.mark.parametrize("step", recovery.PRODUCER_STEPS)
def test_no_recovery_without_every_successful_producer_step(tmp_path, retained, step):
    next(s for s in retained[2]["steps"] if s["name"] == step)["conclusion"] = "failure"
    with pytest.raises(ValueError, match="successful original"):
        retrieve(tmp_path)


@pytest.mark.parametrize(
    "field,value",
    [
        ("run_attempt", 2),
        ("head_sha", HEAD),
        ("run_id", 43),
        ("status", "in_progress"),
        ("started_at", END),
    ],
)
def test_producer_job_attempt_and_source_are_exact(tmp_path, retained, field, value):
    retained[2][field] = value
    with pytest.raises(ValueError, match="successful original"):
        retrieve(tmp_path)


@pytest.mark.parametrize(
    "change", ["fork", "workflow", "event", "pr", "expired", "unrelated", "inputs"]
)
def test_other_sources_are_not_reused(tmp_path, retained, monkeypatch, change):
    artifact, run, _, _, comparison, *_ = retained
    if change == "fork":
        run["head_repository"]["full_name"] = "fork/repo"
    if change == "workflow":
        run["path"] = ".github/workflows/other.yml"
    if change == "event":
        run["event"] = "workflow_dispatch"
    if change == "pr":
        run["pull_requests"] = [{"number": 132}]
    if change == "expired":
        artifact["expired"] = True
    if change == "unrelated":
        comparison["status"] = "diverged"
    if change == "inputs":
        monkeypatch.setattr(recovery, "compatible", lambda *args: False)
    assert retrieve(tmp_path) == {"hit": "false"}


@pytest.mark.parametrize("side", ["head", "base"])
def test_current_pr_cannot_be_a_fork(tmp_path, retained, side):
    retained[3][side]["repo"]["full_name"] = "fork/repo"
    with pytest.raises(ValueError, match="repository/head"):
        retrieve(tmp_path)


def test_artifact_digest_is_checked_before_reading_bytes(tmp_path, retained):
    retained[0]["digest"] = "sha256:" + "0" * 64
    with pytest.raises(ValueError, match="ZIP digest mismatch"):
        retrieve(tmp_path)


@pytest.mark.parametrize("change", ["run", "attempt", "timestamp"])
def test_artifact_is_bound_to_the_original_upload(tmp_path, retained, change):
    artifact = retained[0]
    if change == "run":
        artifact["workflow_run"]["id"] = 43
    elif change == "attempt":
        artifact["name"] = f"ubuntu-acceptance-application-{SOURCE}-99"
    else:
        artifact["created_at"] = "2026-10-19T07:00:00Z"
    with pytest.raises(ValueError, match="successful original"):
        retrieve(tmp_path)


def test_bundle_file_hashes_are_verified_after_archive_checksums(tmp_path, retained):
    artifact, _, _, _, _, receipt, archive, write_zip = retained
    original = tmp_path / "original/open-foresight"
    (original / "app/open-foresight").write_bytes(b"corrupted compiled application")
    with tarfile.open(tmp_path / "application.tar.gz", "w:gz") as tar:
        tar.add(original, arcname="open-foresight")
    receipt["sha256"] = recovery.artifacts.digest(tmp_path / "application.tar.gz")
    write_zip()
    artifact["digest"] = "sha256:" + recovery.artifacts.digest(archive)
    with pytest.raises(ValueError, match="Bundle hash mismatch"):
        retrieve(tmp_path)


@pytest.mark.parametrize("kind", ["runs", "artifacts", "jobs"])
def test_history_pagination_keeps_older_valid_outputs_reusable(
    tmp_path, retained, monkeypatch, kind
):
    original = recovery.artifacts.api
    key = "workflow_runs" if kind == "runs" else kind
    observed = []

    def api(repo, route):
        relevant = (
            (kind == "runs" and route.startswith("actions/workflows/"))
            or (kind == "artifacts" and "/artifacts?" in route)
            or (kind == "jobs" and "/jobs?" in route)
        )
        if not relevant:
            return original(repo, route)
        observed.append(route)
        first = route.rsplit("&page=", 1)[0] + "&page=1"
        value = original(repo, first)[key][0]
        if route.endswith("&page=1"):
            batch = [{**value, "id": 1000 + i} for i in range(100)]
            for item in batch:
                if kind == "runs":
                    item["path"] = ".github/workflows/other.yml"
                else:
                    item["name"] = "unrelated-output"
            return {key: batch}
        assert route.endswith("&page=2")
        return {key: [value]}

    monkeypatch.setattr(recovery.artifacts, "api", api)
    assert retrieve(tmp_path)["hit"] == "true"
    assert any(route.endswith("&page=2") for route in observed)


@pytest.mark.parametrize(
    "field,value",
    [
        ("repositoryName", "fork/repo"),
        ("path", ".github/workflows/other.yml"),
        (
            "repositoryFileUrl",
            f"https://github.com/fork/repo/blob/{SOURCE}/{recovery.WORKFLOW}",
        ),
    ],
)
def test_producer_workflow_head_file_is_repository_bound(
    tmp_path, retained, field, value
):
    file = {
        "repositoryName": REPO,
        "path": recovery.WORKFLOW,
        "repositoryFileUrl": f"https://github.com/{REPO}/blob/{SOURCE}/{recovery.WORKFLOW}",
    }
    file[field] = value
    retained[1]["_workflow_record"] = {
        "data": {"node": {"databaseId": 42, "file": file}}
    }
    with pytest.raises(ValueError, match="workflow head-file"):
        retrieve(tmp_path)


def test_mutable_pr_head_refs_do_not_relabel_the_producer_workflow(tmp_path, retained):
    retained[1]["pull_requests"][0]["head"]["sha"] = HEAD
    assert retrieve(tmp_path)["producer_workflow_head"] == SOURCE


@pytest.mark.parametrize("failure", ["wrong_run", "missing_file", "query_errors"])
def test_invalid_workflow_head_record_cannot_authorize_recovery(
    tmp_path, retained, failure
):
    record = {
        "data": {
            "node": {
                "databaseId": 42,
                "file": {
                    "repositoryName": REPO,
                    "path": recovery.WORKFLOW,
                    "repositoryFileUrl": f"https://github.com/{REPO}/blob/{SOURCE}/{recovery.WORKFLOW}",
                },
            }
        }
    }
    if failure == "wrong_run":
        record["data"]["node"]["databaseId"] = 43
    elif failure == "missing_file":
        record["data"]["node"]["file"] = None
    else:
        record["errors"] = [{"message": "workflow file unavailable"}]
    retained[1]["_workflow_record"] = record
    with pytest.raises(ValueError, match="workflow head-file"):
        retrieve(tmp_path)


def test_repeated_history_pages_fail_without_authorizing_a_build(monkeypatch):
    observed = []

    def api(repo, route):
        observed.append(route)
        return {"artifacts": [{"id": i} for i in range(100)]}

    monkeypatch.setattr(recovery.artifacts, "api", api)
    with pytest.raises(ValueError, match="Repeated history page"):
        list(recovery.pages(REPO, "actions/artifacts?per_page=100", "artifacts"))
    assert len(observed) == 2


def test_main_preserves_captured_api_failure_output(monkeypatch, capsys):
    monkeypatch.setattr(
        recovery.sys,
        "argv",
        [
            "recovery",
            "--head",
            HEAD,
            "--pr",
            "131",
            "--branch",
            "fix/review",
            "--workflow-source",
            HEAD,
        ],
    )
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)

    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(
            1,
            ["gh", "api"],
            output=b'{"status":"503","message":"Service Unavailable"}',
            stderr=b"retry pending",
        )

    monkeypatch.setattr(recovery, "retrieve", fail)
    with pytest.raises(subprocess.CalledProcessError):
        recovery.main()
    output = capsys.readouterr().err
    assert "Service Unavailable" in output and "retry pending" in output


@pytest.mark.parametrize("status", ["404", "503"])
def test_unavailable_old_source_is_distinct_from_an_api_outage(
    tmp_path, retained, monkeypatch, status
):
    original = recovery.artifacts.api

    def api(repo, route):
        if route == f"compare/{SOURCE}...{HEAD}":
            raise subprocess.CalledProcessError(
                1, ["gh", "api"], output=json.dumps({"status": status}).encode()
            )
        return original(repo, route)

    monkeypatch.setattr(recovery.artifacts, "api", api)
    if status == "404":
        assert retrieve(tmp_path) == {"hit": "false"}
    else:
        with pytest.raises(subprocess.CalledProcessError):
            retrieve(tmp_path)


@pytest.mark.parametrize(
    "old,new",
    [
        ("runs-on: ubuntu-24.04", "runs-on: ubuntu-22.04"),
        ("timeout-minutes: 300", "timeout-minutes: 299"),
        ("ref: ${{ github.event.pull_request.head.sha || github.sha }}", "ref: main"),
        (
            'daemon-config: \'{"features":{"containerd-snapshotter":true}}\'',
            'daemon-config: \'{"features":{"containerd-snapshotter":false}}\'',
        ),
        ("driver: docker", "driver: docker-container"),
        (
            "docker create foresight-built-application:local",
            "docker create unverified-image:local",
        ),
        (
            "python3 packaging/package_linux.py --bundle",
            "python3 packaging/unverified_packager.py --bundle",
        ),
        (
            "python tools/ci_app_build_transport.py",
            "python tools/different_transport.py",
        ),
        ("    steps:\n", "    env:\n      CXXFLAGS: -O0\n    steps:\n"),
        (
            "    steps:\n",
            "    defaults:\n      run:\n        shell: custom-shell\n    steps:\n",
        ),
    ],
)
def test_all_product_producer_bindings_are_checked(old, new):
    text = (recovery.ROOT / recovery.WORKFLOW).read_text()
    start = text.index("  ubuntu-package:\n")
    assert old in text[start:]
    changed = text[:start] + text[start:].replace(old, new, 1)
    assert recovery.build_controls(text) != recovery.build_controls(changed)


def test_workflow_global_environment_and_recovery_contract_are_checked():
    text = (recovery.ROOT / recovery.WORKFLOW).read_text()
    assert recovery.build_controls(text) != recovery.build_controls(
        "env:\n  CXXFLAGS: -O0\n" + text
    )
    changed = text.replace(
        '--workflow-source "$WORKFLOW_SOURCE"', '--workflow-source "$OWN_HEAD"'
    )
    with pytest.raises(ValueError, match="read-only contract"):
        recovery.build_controls(changed)


@pytest.mark.parametrize("location", ["workflow", "job"])
@pytest.mark.parametrize("key", ["env", "defaults"])
def test_build_affecting_keys_cannot_hide_after_steps_or_jobs(location, key):
    text = (recovery.ROOT / recovery.WORKFLOW).read_text()
    if location == "workflow":
        changed = text + f"\n{key}:\n  fixture: changed\n"
        message = "workflow keys after jobs"
    else:
        changed = text + f"\n    {key}:\n      fixture: changed\n"
        message = "job keys after steps"
    with pytest.raises(ValueError, match=message):
        recovery.build_controls(changed)


def test_ambiguous_producer_jobs_and_external_yaml_aliases_are_rejected():
    text = (recovery.ROOT / recovery.WORKFLOW).read_text()
    with pytest.raises(ValueError, match="Ambiguous application producer"):
        recovery.build_controls(text + "\n  ubuntu-package:\n    steps: []\n")
    with pytest.raises(ValueError, match="anchors or aliases"):
        recovery.build_controls("env: &external\n  CXXFLAGS: changed\n" + text)


def test_main_history_detects_an_intermediate_recipe_change_and_revert(
    tmp_path, monkeypatch
):
    # Independent short history, including in source exports with no repository.
    root = tmp_path / "main-proof"
    root.mkdir()

    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(root), *args], text=True, timeout=30
        ).strip()

    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    git("config", "commit.gpgsign", "false")
    workflow = root / recovery.WORKFLOW
    workflow.parent.mkdir(parents=True)
    text = (recovery.ROOT / recovery.WORKFLOW).read_text()
    workflow.write_text(text)
    git("add", ".")
    git("commit", "-qm", "frozen source and main fork point")
    source = main_tip = git("rev-parse", "HEAD")

    def api(repo, route):
        assert repo == REPO and route == "commits/main"
        return {"sha": main_tip}

    monkeypatch.setattr(recovery.artifacts, "api", api)
    assert recovery.main_history(REPO, root, source, source) == {
        "main_history_tip": source,
        "main_history_merge_base": source,
    }
    (root / "README.md").write_text("Unrelated main documentation")
    git("add", ".")
    git("commit", "-qm", "unchanged main build controls")
    main_tip = git("rev-parse", "HEAD")
    assert (
        recovery.main_history(REPO, root, source, source)["main_history_tip"]
        == main_tip
    )
    workflow.write_text(text.replace("runs-on: ubuntu-24.04", "runs-on: ubuntu-22.04"))
    git("commit", "-qam", "main temporarily changed the build runner")
    workflow.write_text(text)
    git("commit", "-qam", "main reverted the runner change")
    main_tip = git("rev-parse", "HEAD")
    assert recovery.build_controls(
        git("show", main_tip + ":" + recovery.WORKFLOW)
    ) == recovery.build_controls(text)
    with pytest.raises(
        ValueError, match="Main changed original merge-ref build controls"
    ):
        recovery.main_history(REPO, root, source, source)


@pytest.mark.parametrize(
    "field,value",
    [
        ("revision", HEAD),
        ("sha256", "0" * 64),
        ("source_date_epoch", -1),
        ("build_number", 11),
    ],
)
def test_original_receipt_and_manifest_are_not_rewritten(
    tmp_path, retained, field, value
):
    artifact, _, _, _, _, receipt, archive, write_zip = retained
    receipt[field] = value
    write_zip()
    artifact["digest"] = "sha256:" + recovery.artifacts.digest(archive)
    with pytest.raises(ValueError, match="mismatch|differs|timestamp"):
        retrieve(tmp_path)


def test_checksum_valid_archive_cannot_escape_bundle_root(tmp_path, retained):
    artifact, _, _, _, _, receipt, archive, write_zip = retained
    with tarfile.open(tmp_path / "application.tar.gz", "w:gz") as tar:
        member = tarfile.TarInfo("open-foresight/../../escaped")
        member.size = 4
        tar.addfile(member, io.BytesIO(b"evil"))
    receipt["sha256"] = recovery.artifacts.digest(tmp_path / "application.tar.gz")
    write_zip()
    artifact["digest"] = "sha256:" + recovery.artifacts.digest(archive)
    with pytest.raises(tarfile.FilterError):
        retrieve(tmp_path)
    assert not (tmp_path / "escaped").exists()


def test_compatibility_reads_git_objects_without_producer_execution(tmp_path):
    # A tiny self-contained history; works in full source exports without .git.
    root = tmp_path / "repo"
    root.mkdir()

    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(root), *args], text=True, timeout=30
        ).strip()

    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    workflow = root / recovery.WORKFLOW
    workflow.parent.mkdir(parents=True)
    workflow.write_text(
        "jobs:\n  ubuntu-package:\n    runs-on: ubuntu-24.04\n    steps:\n"
        + "".join(
            "      - name: "
            + name
            + "\n        if: github.event_name == 'pull_request'\n        run: pinned-build-input\n"
            for name in recovery.PRODUCER_STEPS
        )
    )
    (root / "app.dart").write_text("original application")
    git("add", ".")
    git("commit", "-qm", "frozen original")
    source = git("rev-parse", "HEAD")
    workflow.write_text(
        workflow.read_text().replace(
            "- name: "
            + recovery.BUILD_STEPS[1]
            + "\n        if: github.event_name == 'pull_request'",
            "- name: "
            + recovery.BUILD_STEPS[1]
            + "\n        if: github.event_name == 'pull_request' && steps.retained.outputs.hit != 'true'",
        )
    )
    git("commit", "-qam", "recovery condition only")
    head = git("rev-parse", "HEAD")
    assert recovery.compatible(root, source, head)
    workflow.write_text(
        workflow.read_text().replace("pinned-build-input", "different-compiler-input")
    )
    git("commit", "-qam", "changed build binding")
    assert not recovery.compatible(root, source, git("rev-parse", "HEAD"))
    workflow.write_text(
        workflow.read_text().replace("runs-on: ubuntu-24.04", "runs-on: ubuntu-22.04")
    )
    git("commit", "-qam", "executed merge-ref workflow uses a different runner")
    actual_workflow = git("rev-parse", "HEAD")
    assert recovery.compatible(root, source, head, source)
    assert not recovery.compatible(root, source, head, actual_workflow)
    workflow.write_text(
        workflow.read_text()
        .replace("different-compiler-input", "pinned-build-input")
        .replace("runs-on: ubuntu-22.04", "runs-on: ubuntu-24.04")
    )
    (root / "app.dart").write_text("changed application")
    git("commit", "-qam", "changed application")
    assert not recovery.compatible(root, source, git("rev-parse", "HEAD"))


def test_workflow_skips_every_application_producer_when_recovered():
    document = yaml.safe_load((recovery.ROOT / recovery.WORKFLOW).read_text())
    steps = document["jobs"]["ubuntu-package"]["steps"]
    skipped = recovery.BUILD_STEPS[1:] + recovery.PRODUCER_STEPS[4:]
    for name in skipped:
        step = next(s for s in steps if s.get("name") == name)
        assert "steps.retained.outputs.hit != 'true'" in step["if"]
    recovery_step = next(s for s in steps if s.get("id") == "retained")
    assert "head.repo.full_name == github.repository" in recovery_step["if"]
    assert recovery_step["env"]["WORKFLOW_SOURCE"] == "${{ github.workflow_sha }}"
    assert '--workflow-source "$WORKFLOW_SOURCE"' in recovery_step["run"]
