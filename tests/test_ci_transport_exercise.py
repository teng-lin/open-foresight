"""Real qualification command orchestration never authorizes SDK recompilation."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

from tools import ci_transport_exercise as exercise

SOURCE = "a" * 40


@pytest.fixture
def application(tmp_path):
    root = tmp_path / "application"
    handoff = root / "handoff"
    handoff.mkdir(parents=True)
    archive = handoff / "source-build.tar.gz"
    archive.write_bytes(b"actual fixture archive bytes")
    inputs = {"ci_recipe_sha256": "b" * 64, "tooling_identity": {"digest": "c" * 64}}
    (root / "ci-inputs.json").write_text(json.dumps(inputs))
    (handoff / "source-build.json").write_text(json.dumps({"source": SOURCE, "inputs": inputs, "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}))
    packages = root / "packages"
    packages.mkdir()
    package = packages / "open-foresight-1.0-1-linux-x86_64.tar.gz"
    package.write_bytes(b"original portable fixture")
    checksum = hashlib.sha256(package.read_bytes()).hexdigest()
    package.with_name(package.name + ".sha256").write_text(checksum + "  " + package.name + "\n")
    package.with_name(package.name + ".build.json").write_text(json.dumps({"revision": SOURCE, "sha256": checksum, "format": "tar"}))
    evidence = root / "evidence"
    for relative in ("test-results/linux/native/results.xml", "test-results/service/results.xml"):
        path = evidence / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('<testsuites><testsuite><testcase name="actual-fixture"/></testsuite></testsuites>')
    host = evidence / "coverage/python/linux-contracts.xml"
    host.parent.mkdir(parents=True)
    host.write_text('<testsuites><testsuite>' + ''.join(f'<testcase classname="{name.removesuffix(".py").replace("/", ".")}"/>' for name in exercise.platform_python_tests.SHARED + exercise.platform_python_tests.PLATFORM["linux"]) + '</testsuite></testsuites>')
    for language, coverage in (("core", "coverage/core/lcov.info"), ("desktop", "apps/desktop/coverage/lcov.info")):
        path = evidence / f"test-results/linux/{language}/{language}.events.jsonl"
        path.parent.mkdir(parents=True)
        events = [{"type": "suite", "suite": {"id": 0, "path": language + ".dart"}}, {"type": "testStart", "test": {"id": 1, "suiteID": 0, "name": "actual fixture"}}, {"type": "testDone", "testID": 1, "result": "success", "hidden": False, "skipped": False}, {"type": "done", "success": True}]
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        path = evidence / coverage
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("SF:fixture.dart\nDA:1,1\nend_of_record\n")
    return root


def test_actual_report_adapter_binds_handoff_packages_and_fresh_complete_test_outputs(application):
    report = exercise.application_record("archive-sdk", SOURCE, application)
    assert report["junit"]["service"] == {"tests": 1, "skipped": 0}
    assert report["languages"]["core"] == {"cases": 1, "skipped": 0, "covered": 1, "lines": 1}
    assert report["portable"]["sha256"] == hashlib.sha256(b"original portable fixture").hexdigest()
    assert report["ci_inputs"]["tooling_identity"] == {"digest": "c" * 64}


@pytest.mark.parametrize("fault", ["archive", "source", "native", "service-skip", "host", "coverage", "events", "portable"])
def test_record_adapter_rejects_changed_bytes_missing_coverage_or_failed_tests(application, fault):
    if fault == "archive":
        (application / "handoff/source-build.tar.gz").write_bytes(b"changed")
    elif fault == "source":
        manifest = application / "handoff/source-build.json"
        value = json.loads(manifest.read_text())
        value["source"] = "b" * 40
        manifest.write_text(json.dumps(value))
    elif fault == "native":
        (application / "evidence/test-results/linux/native/results.xml").write_text('<testsuite><testcase><failure/></testcase></testsuite>')
    elif fault == "service-skip":
        (application / "evidence/test-results/service/results.xml").write_text('<testsuite><testcase><skipped/></testcase></testsuite>')
    elif fault == "host":
        (application / "evidence/coverage/python/linux-contracts.xml").write_text('<testsuite><testcase><error/></testcase></testsuite>')
    elif fault == "coverage":
        (application / "evidence/coverage/core/lcov.info").write_text('SF:fixture.dart\nDA:1,0\nend_of_record\n')
    elif fault == "events":
        (application / "evidence/test-results/linux/desktop/desktop.events.jsonl").write_text('{"type":"done","success":false}\n')
    else:
        (application / "packages/open-foresight-1.0-1-linux-x86_64.tar.gz").write_bytes(b"changed")
    with pytest.raises(ValueError):
        exercise.application_record("archive-sdk", SOURCE, application)


def test_failed_real_command_output_is_preserved(tmp_path, monkeypatch):
    monkeypatch.setattr(exercise.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 7, "actual failed fixture output"))
    with pytest.raises(subprocess.CalledProcessError) as error:
        exercise.run(["docker", "run", "fixture"], root=tmp_path, output=tmp_path)
    assert error.value.output == "actual failed fixture output"
    assert "actual failed fixture output" in (tmp_path / "commands.log").read_text()


@pytest.mark.parametrize("kind", ["archive-sdk", "fork-sdk", "recipe-change"])
@pytest.mark.parametrize("fault", ["", "checkout", "missing-sdk", "scope", "provenance", "image", "driver"])
def test_real_exercise_calls_actual_driver_and_preserves_original_sdk_provenance(tmp_path, monkeypatch, kind, fault):
    source = tmp_path / "source"
    source.mkdir()
    recipe = source / "packaging/ci-tooling.Dockerfile"
    recipe.parent.mkdir()
    before = b'FROM ${SDK_IMAGE} AS ci-tooling\nRUN original_tooling\n'
    recipe.write_bytes(before)
    for key, value in {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_SHA": SOURCE, "GITHUB_REPOSITORY": "owner/repo"}.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(exercise.subprocess, "check_output", lambda *a, **kw: ("b" * 40 if fault == "checkout" else SOURCE) + "\n")
    monkeypatch.setattr(exercise.ci_rollout, "closure", lambda root: {"schema": 1, "sha256": "d" * 64, "files": {}})
    def fetch(repository, component, prefix, *args):
        if fault == "missing-sdk":
            return False
        prefix.mkdir(parents=True)
        (prefix / "source-qualification.json").write_text('{"original":"receipt"}')
        return True
    monkeypatch.setattr(exercise.waiter, "fetch", fetch)
    monkeypatch.setattr(exercise.shadow, "reference", lambda *args: {"original": "receipt"})
    monkeypatch.setattr(exercise.sdk, "resolve", lambda *args, **kwargs: "verified-image")
    inspections = []
    def inspect(*args):
        inspections.append(args)
        return "sha256:" + ("2" if fault == "image" and len(inspections) > 1 else "1") * 64
    monkeypatch.setattr(exercise.sdk, "inspect", inspect)
    def save(source, image, envelope, **kwargs):
        envelope.mkdir(parents=True)
        (envelope / "identity.json").write_text(json.dumps({"tier": "pr", "reused_from": {"original": "changed" if fault == "provenance" else "receipt"}}))
        (envelope / "payload.tar.gz").write_bytes(b"fixture original payload")
    monkeypatch.setattr(exercise.application, "save_sdk", save)
    def unpack(component, identity, envelope, restored):
        restored.mkdir(parents=True)
        (restored / "image.tar").write_bytes(b"original verified archive")
        (restored / "source-qualification.json").write_text('{"original":"receipt"}')
    monkeypatch.setattr(exercise.artifacts, "unpack", unpack)
    monkeypatch.setattr(exercise.sdk, "write_outputs", lambda image: None)
    monkeypatch.setattr(exercise.artifacts, "fingerprint", lambda *args: "identity")
    monkeypatch.setattr(exercise.artifacts, "digest", lambda path: "recipe-digest" if path.name.endswith(".py") else hashlib.sha256(path.read_bytes()).hexdigest())
    monkeypatch.setattr(exercise.sdk, "record", lambda *args: {"source_scope": "b" * 40 if fault == "scope" else SOURCE, "local_recipe_sha256": "recipe-digest"})
    monkeypatch.setattr(exercise.sdk, "load", lambda *args: "loaded-archive")
    commands = []
    def run(command, **kwargs):
        commands.append(command)
        if fault == "driver":
            raise RuntimeError("real driver failure")
        if kind == "recipe-change":
            assert recipe.read_bytes() != before
    monkeypatch.setattr(exercise, "run", run)
    monkeypatch.setattr(exercise, "application_record", lambda *args: {"actual": "application-report"})
    applicable = fault not in {"scope", "provenance"} or kind != "recipe-change"
    if fault and applicable:
        with pytest.raises((ValueError, RuntimeError)):
            exercise.exercise(kind, SOURCE, tmp_path / "output", root=source)
        assert recipe.read_bytes() == before
        return
    result = exercise.exercise(kind, SOURCE, tmp_path / "output", root=source)
    assert result["original_sdk"] == {"original": "receipt"}
    assert result["application"] == {"actual": "application-report"}
    if kind == "fork-sdk":
        assert result["consumer"] == "shadow-fork-sdk"
        assert result["reused_archive"] is True
        assert not (tmp_path / "output/restored").exists()
    assert commands[0][:2] == ["bash", "tools/build_linux_container.sh"]
    assert recipe.read_bytes() == before


def test_exercise_never_starts_for_prs_or_unknown_modes(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_REF", "refs/pull/999/merge")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    for kind in ("invalid", "archive-sdk"):
        with pytest.raises(ValueError):
            exercise.exercise(kind, SOURCE, tmp_path / "output")


def test_record_cli_only_reads_actual_application_outputs(tmp_path, application, monkeypatch):
    path = tmp_path / "report/publisher.json"
    monkeypatch.setattr(sys, "argv", ["exercise", "--kind", "archive-sdk", "--source", SOURCE, "--record-application", str(application), "--output", str(path)])
    exercise.main()
    assert json.loads(path.read_text())["kind"] == "archive-sdk"


def test_successful_command_output_is_retained(tmp_path, monkeypatch):
    monkeypatch.setattr(exercise.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, "successful real command output"))
    exercise.run(["docker", "inspect", "fixture"], root=tmp_path, output=tmp_path)
    assert "successful real command output" in (tmp_path / "commands.log").read_text()


@pytest.fixture
def publisher_proof(monkeypatch):
    repository = "owner/repo"
    identity = {"identity": "c" * 64}
    digest = "sha256:" + "d" * 64
    run = {"id": 7, "head_sha": SOURCE, "head_branch": "main", "event": "workflow_dispatch", "path": ".github/workflows/linux-cache-publish.yml", "repository": {"full_name": repository}, "head_repository": {"full_name": repository}}
    job = {"id": 70, "name": "publish-linux-caches", "run_id": 7, "run_attempt": 1, "conclusion": "success", "started_at": "2026-10-20T00:00:00Z", "completed_at": "2026-10-20T00:10:00Z", "steps": [{"name": exercise.PUBLISH_STEP, "status": "completed", "conclusion": "success"}]}
    artifact = {"id": 9, "name": "ci-tooling-" + identity["identity"], "digest": "sha256:" + "e" * 64, "expired": False, "workflow_run": {"id": 7}, "created_at": "2026-10-20T00:05:00Z"}
    receipt = {"schema": 1, "component": "linux-ci-tooling", "inputs": identity, "repository": repository, "tier": "tooling", "label": "", "source_commit": SOURCE, "source_run_id": 7, "source_run_attempt": 1, "source_job_id": 70, "image_digest": digest}
    record = {"ci_inputs": {"tooling_identity": identity["identity"]}, "publisher": {"run_id": 7, "attempt": 1, "job_id": 70}, "tooling": {"artifact": artifact.copy(), "receipt": receipt, "resolution": {"reused": True, "inputs": identity, "image": exercise.tooling.image_reference(repository, digest)}}}
    def api(repo, route):
        assert repo == repository
        if route == "actions/runs/7":
            return run
        if route == "actions/artifacts/9":
            return artifact
        if route == "actions/runs/7/attempts/1/jobs?per_page=100&page=1":
            return {"jobs": [job]}
        if route == f"compare/{SOURCE}...main":
            return {"status": "identical"}
        raise AssertionError(route)
    monkeypatch.setattr(exercise.artifacts, "api", api)
    return record, run, job, artifact, api


def test_publisher_proof_requires_actual_verified_shared_pull_and_current_run_publication(publisher_proof):
    record, _, _, _, api = publisher_proof
    assert exercise.verify_publisher_proof(record, "owner/repo", SOURCE, 7, api=api) is record


@pytest.mark.parametrize("fault", ["miss", "identity", "image", "receipt", "other-run", "failed", "skipped-publication", "main", "checksum", "attempt"])
def test_publisher_proof_rejects_local_fallback_and_unrelated_or_failed_publishers(publisher_proof, fault):
    record, run, job, artifact, api = publisher_proof
    if fault == "miss":
        record["tooling"]["resolution"]["reused"] = False
    elif fault == "identity":
        record["ci_inputs"]["tooling_identity"] = "wrong"
    elif fault == "image":
        record["tooling"]["resolution"]["image"] = "locally-built-image"
    elif fault == "receipt":
        record["tooling"]["receipt"]["source_job_id"] = 71
    elif fault == "other-run":
        record["publisher"]["run_id"] = 8
    elif fault == "failed":
        job["conclusion"] = "failure"
    elif fault == "skipped-publication":
        job["steps"][0]["conclusion"] = "skipped"
    elif fault == "main":
        run["head_branch"] = "other"
    elif fault == "checksum":
        artifact["digest"] = "sha256:" + "f" * 64
    else:
        job["run_attempt"] = 2
    with pytest.raises(ValueError):
        exercise.verify_publisher_proof(record, "owner/repo", SOURCE, 7, api=api)


def test_publisher_application_record_retains_real_tooling_and_publisher_provenance(application, publisher_proof, monkeypatch):
    proof, _, job, _, _ = publisher_proof
    inputs = json.loads((application / "ci-inputs.json").read_text())
    inputs["tooling_identity"] = "c" * 64
    (application / "ci-inputs.json").write_text(json.dumps(inputs))
    manifest = application / "handoff/source-build.json"
    value = json.loads(manifest.read_text())
    value["inputs"] = inputs
    manifest.write_text(json.dumps(value))
    directory = application / "tooling"
    directory.mkdir()
    (directory / "inputs.json").write_text(json.dumps(proof["tooling"]["resolution"]))
    (directory / "producer.json").write_text(json.dumps({key: value for key, value in proof["tooling"].items() if key != "resolution"}))
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setenv("GITHUB_RUN_ID", "7")
    monkeypatch.setattr(exercise.artifacts, "dependency_jobs", lambda *args: [job])
    result = exercise.application_record("publisher", SOURCE, application)
    assert result["publisher"] == {"run_id": 7, "attempt": 1, "job_id": 70}
    assert result["tooling"]["receipt"]["image_digest"] == "sha256:" + "d" * 64


def test_local_tooling_miss_has_actionable_failure_before_any_api_or_producer_read(tmp_path, monkeypatch):
    directory = tmp_path / "tooling"
    directory.mkdir()
    (directory / "inputs.json").write_text('{"reused":false}')
    def forbidden(*args):
        raise AssertionError("Known local fallback must not query publishers")
    monkeypatch.setattr(exercise.artifacts, "dependency_jobs", forbidden)
    with pytest.raises(ValueError, match="Local tooling fallback cannot qualify"):
        exercise.publisher_record(tmp_path, {}, SOURCE)


def test_hosted_publisher_record_has_api_credentials_and_read_permission():
    config = yaml.safe_load((Path(__file__).resolve().parents[1] / ".github/workflows/linux-cache-publish.yml").read_text())
    consumer = config["jobs"]["qualification-consumers"]
    record = next(step for step in consumer["steps"] if "--kind publisher" in step.get("run", ""))
    assert record["env"]["GH_TOKEN"] == "${{ github.token }}"
    assert consumer["permissions"]["actions"] == "read"


@pytest.mark.parametrize("section,key", [("publisher", "run_id"), ("publisher", "attempt"), ("publisher", "job_id"), ("artifact", "id"), ("receipt", "source_run_id"), ("receipt", "source_run_attempt"), ("receipt", "source_job_id")])
@pytest.mark.parametrize("invalid", [None, 0, -1, True, "7"])
def test_nested_publisher_identities_are_validated_before_api_calls(publisher_proof, section, key, invalid):
    record, *_ = publisher_proof
    target = record[section] if section == "publisher" else record["tooling"][section]
    target[key] = invalid
    with pytest.raises(ValueError, match="positive original"):
        exercise.verify_publisher_proof(record, "owner/repo", SOURCE, 7, api=lambda *args: pytest.fail("Malformed identity must not reach API"))


@pytest.mark.parametrize("diagnostic,missing", [("gh: Not Found (HTTP 404)", True), (b"gh: Not Found (HTTP 404)", True), ("gh: Forbidden (HTTP 403)", False), ("gh: server error (HTTP 503)", False), ("connection unavailable", False), ("HTTP 404; upstream HTTP 403", False)])
@pytest.mark.parametrize("route", ["actions/artifacts/9", "actions/runs/7", "actions/runs/7/attempts/1/jobs?per_page=100&page=1", f"compare/{SOURCE}...main"])
def test_missing_nested_publisher_records_revoke_proof_but_transport_failures_propagate(publisher_proof, diagnostic, missing, route):
    record, _, _, _, api = publisher_proof
    def get(repository, requested):
        if requested == route:
            raise subprocess.CalledProcessError(1, ["gh", "api"], stderr=diagnostic)
        return api(repository, requested)
    with pytest.raises(ValueError if missing else subprocess.CalledProcessError):
        exercise.verify_publisher_proof(record, "owner/repo", SOURCE, 7, api=get)


def test_current_publication_may_consume_an_older_verified_tooling_image(publisher_proof):
    record, run, job, artifact, api = publisher_proof
    record["tooling"]["receipt"].update(source_run_id=6, source_job_id=60)
    artifact["workflow_run"] = {"id": 6}
    record["tooling"]["artifact"] = artifact.copy()
    def get(repository, route):
        if route == "actions/runs/6":
            return {**run, "id": 6}
        if route == "actions/runs/6/attempts/1/jobs?per_page=100&page=1":
            return {"jobs": [{**job, "id": 60, "run_id": 6}]}
        return api(repository, route)
    assert exercise.verify_publisher_proof(record, "owner/repo", SOURCE, 7, api=get) is record
