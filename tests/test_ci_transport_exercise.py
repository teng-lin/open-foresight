"""Real qualification command orchestration never authorizes SDK recompilation."""

import hashlib
import json
import subprocess
import sys

import pytest

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
    report = exercise.application_record("publisher", SOURCE, application)
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
        exercise.application_record("publisher", SOURCE, application)


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
    recipe = source / "packaging/build.Dockerfile"
    recipe.parent.mkdir()
    before = b'FROM ${SDK_IMAGE} AS application-base\nRUN original_tooling\n'
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
        (envelope / "identity.json").write_text(json.dumps({"reused_from": {"original": "changed" if fault == "provenance" else "receipt"}}))
        (envelope / "payload.tar.gz").write_bytes(b"fixture original payload")
    monkeypatch.setattr(exercise.application, "save_sdk", save)
    monkeypatch.setattr(exercise.artifacts, "unpack", lambda *args: None)
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
    monkeypatch.setattr(sys, "argv", ["exercise", "--kind", "publisher", "--source", SOURCE, "--record-application", str(application), "--output", str(path)])
    exercise.main()
    assert json.loads(path.read_text())["kind"] == "publisher"


def test_successful_command_output_is_retained(tmp_path, monkeypatch):
    monkeypatch.setattr(exercise.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, "successful real command output"))
    exercise.run(["docker", "inspect", "fixture"], root=tmp_path, output=tmp_path)
    assert "successful real command output" in (tmp_path / "commands.log").read_text()
