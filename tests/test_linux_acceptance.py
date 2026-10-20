"""Own-run acceptance keeps portable bytes intact and independent suites visible."""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import zipfile

import pytest
import yaml

from tests.test_integration_application import producer as producer, SOURCE
from tools import ci_linux_acceptance as acceptance
from tools.ci_artifacts import digest

ROOT = Path(__file__).resolve().parents[1]


def test_prepared_bundle_is_the_checksum_verified_original(producer, tmp_path):
    packages = producer[0]
    destination = tmp_path / "portable"
    original = (packages / "application.tar.gz").read_bytes()
    assert acceptance.prepare(packages, destination, SOURCE) == {
        "source": SOURCE,
        "version": "0.1.2",
        "release": "1",
    }
    assert (
        destination / "open-foresight/executable"
    ).read_bytes() == b"immutable original application"
    assert (destination / "open-foresight/executable").stat().st_mode & 0o111
    assert (packages / "application.tar.gz").read_bytes() == original
    with pytest.raises(ValueError, match="preserve"):
        acceptance.prepare(packages, destination, SOURCE)


@pytest.mark.parametrize(
    "attack", ["checksum", "escape", "absolute", "link", "duplicate", "empty"]
)
def test_bad_portable_archives_never_install_partial_outputs(
    producer, tmp_path, attack
):
    packages = producer[0]
    package = packages / "application.tar.gz"
    if attack == "checksum":
        package.write_bytes(package.read_bytes() + b"bad")
    else:
        with tarfile.open(package, "w:gz") as archive:
            if attack != "empty":
                name = {
                    "escape": "open-foresight/../outside",
                    "absolute": "/open-foresight/owned",
                }.get(attack, "open-foresight/test")
                entry = tarfile.TarInfo(name)
                entry.size = 1
                if attack == "link":
                    entry.type, entry.linkname, entry.size = (
                        tarfile.SYMTYPE,
                        "/etc/passwd",
                        0,
                    )
                archive.addfile(entry, io.BytesIO(b"x"))
                if attack == "duplicate":
                    archive.addfile(entry, io.BytesIO(b"x"))
        package.with_name(package.name + ".sha256").write_text(
            digest(package) + "  " + package.name + "\n"
        )
    destination = tmp_path / "portable"
    with pytest.raises((ValueError, tarfile.FilterError)):
        acceptance.prepare(packages, destination, SOURCE)
    assert not destination.exists()


@pytest.mark.parametrize("selected", [True, False])
def test_acceptance_aggregate_rejects_missing_failed_or_unexpectedly_skipped_producers(
    selected,
):
    result = "success" if selected else "skipped"
    jobs = {
        name: {"result": result}
        for name in (
            "linux-build",
            "acceptance-cpu",
            "acceptance-audio",
            "acceptance-deb",
        )
    }
    jobs.update(changes={"result": "success"})
    acceptance.check_gates(jobs, selected)
    for name in jobs:
        for status in (
            None,
            "failure",
            "cancelled",
            "success" if result == "skipped" else "skipped",
        ):
            changed = {**jobs, name: {"result": status}}
            if name == "changes" and status == "success":
                continue
            with pytest.raises(ValueError):
                acceptance.check_gates(changed, selected)


@pytest.mark.parametrize(
    "suite,full,packaging,gpu_failure",
    [
        ("cpu", False, False, False),
        ("audio", False, False, False),
        ("audio", False, False, True),
        ("deb", False, False, False),
        ("deb", True, False, False),
        ("deb", False, True, False),
    ],
)
def test_real_shell_orchestration_runs_only_the_selected_consumer(
    tmp_path, suite, full, packaging, gpu_failure
):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "commands.jsonl"
    stub = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
with open(os.environ['COMMAND_LOG'], 'a') as stream:
    stream.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
if sys.argv[1:] == ['context', 'show']:
    print('default')
if os.environ['GPU_FAILURE'] == '1' and 'tools/accept_software_gpu.py' in sys.argv:
    sys.exit(17)
"""
    for command in ("docker", "python", "bash"):
        path = bin_dir / command
        path.write_text(stub)
        path.chmod(0o755)
    # Use the real shell to exercise arrays, failure propagation and all branches;
    # the sandbox setup subcommand is recorded by the separate stub bash.
    env = {
        **os.environ,
        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        "COMMAND_LOG": str(log),
        "GPU_FAILURE": "1" if gpu_failure else "0",
        "VERSION": "0.1.2",
        "SDK_IMAGE": "verified-image",
        "GITHUB_REPOSITORY": "Owner/Repo",
        "SOURCE_DATE_EPOCH": "123",
        "ACCEPTANCE_FULL": str(full).lower(),
        "PACKAGING_SELECTED": str(packaging).lower(),
    }
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "tools/linux_acceptance.sh"), suite],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == (17 if gpu_failure else 0), (
        result.stdout + result.stderr
    )
    rows = [json.loads(line) for line in log.read_text().splitlines()]
    joined = json.dumps(rows)
    assert "--cache-to" not in joined
    assert "sdk.Dockerfile" not in joined and "--target builder" not in joined
    if suite == "deb":
        assert "package-and-test.sh" in joined
        assert ("test-debian.sh" in joined) == (full or packaging)
        assert "integration_gates.py" not in joined
    else:
        assert "--target" in joined and "acceptance" in joined
        assert "--network" in joined and "none" in joined
        assert ("models" in joined) and "--prepare-models-only" in joined
        assert ("virtual-audio" in joined) == (suite == "audio")
        assert ("accept_software_gpu.py" in joined) == (suite == "audio")
        assert "docker" == rows[1][0] or any(row[0] == "docker" for row in rows)


def test_common_action_restores_exact_ids_and_read_only_sdk_inputs():
    action = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-consumer/action.yml").read_text()
    )
    text = json.dumps(action)
    assert (
        "--artifact-id" in text and "--artifact-digest" in text and "--attempt" in text
    )
    assert "--purpose" in text and "--main-candidate" not in text
    assert "--run-id" in text and "--artifact-digest" in text
    assert "Build SDK reference is missing" in text
    assert "--load --discard-archive" in text
    assert "produce" not in " ".join(
        step.get("run", "") for step in action["runs"]["steps"]
    )


@pytest.fixture
def release_input(producer, tmp_path, monkeypatch):
    from tests.test_integration_application import changed_receipt

    package = producer[0] / "application.tar.gz"
    metadata = package.with_name(package.name + ".build.json")
    record = json.loads(metadata.read_text())
    record.update(format="tar", sha256=digest(package))
    metadata.write_text(json.dumps(record))
    changed = changed_receipt(producer, tier="release", label="")
    with zipfile.ZipFile(changed[1]) as archive:
        receipt = json.loads(archive.read("identity.json"))
    qualification = {
        "source_receipt": receipt,
        "producer_repository": "example/foresight",
        "source_repository": "example/foresight",
        "producer_run": 100,
        "producer_attempt": 1,
        "producer_job": 300,
        "artifact_id": 200,
        "artifact_digest": "sha256:" + changed[2],
    }
    (changed[0] / "source-qualification.json").write_text(json.dumps(qualification))
    monkeypatch.setenv("GITHUB_REPOSITORY", "example/foresight")
    monkeypatch.setenv("GITHUB_RUN_ID", "100")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "3")
    return changed[0], qualification


def test_release_consumption_receipt_binds_actual_original_input_and_current_consumer(
    release_input, tmp_path
):
    packages, qualification = release_input
    output = tmp_path / "evidence/consumption.json"
    result = acceptance.record_input(packages, SOURCE, output, "acceptance-cpu")
    assert result == {
        "schema": 1,
        "source": SOURCE,
        "component": "linux-app",
        "artifact_id": 200,
        "artifact_digest": qualification["artifact_digest"],
        "payload_sha256": qualification["source_receipt"]["sha256"],
        "source_run_attempt": 1,
        "consumer_run_id": 100,
        "consumer_run_attempt": 3,
    }
    assert json.loads(output.read_text()) == result
    assert output.stat().st_size < 64 * 1024


@pytest.mark.parametrize(
    "field,value",
    [
        ("producer_run", 101),
        ("producer_attempt", 2),
        ("artifact_id", True),
        ("artifact_digest", "a" * 64),
        ("producer_repository", "other/repo"),
        ("source_repository", "fork/repo"),
    ],
)
def test_consumption_receipts_reject_relabelled_qualifications(
    release_input, tmp_path, field, value
):
    packages, qualification = release_input
    qualification[field] = value
    (packages / "source-qualification.json").write_text(json.dumps(qualification))
    with pytest.raises(ValueError, match="verified own-run"):
        acceptance.record_input(
            packages, SOURCE, tmp_path / "consumption.json", "acceptance-audio"
        )
    assert not (tmp_path / "consumption.json").exists()


@pytest.fixture
def release_handoff(release_input, tmp_path, monkeypatch):
    import shutil
    from tools import ci_linux_handoff as handoff

    packages, _ = release_input
    source = tmp_path / "source"
    directory = source / "dist/packages"
    directory.mkdir(parents=True)
    (source / "compiled").write_bytes(b"compiled application fixture")
    for name in (
        "application.tar.gz",
        "application.tar.gz.sha256",
        "application.tar.gz.build.json",
    ):
        shutil.copy2(packages / name, directory / name)
    inputs = tmp_path / "inputs.json"
    inputs.write_text("{}")
    archive = tmp_path / "handoff"
    with monkeypatch.context() as producer:
        producer.setenv("GITHUB_RUN_ATTEMPT", "1")
        manifest = handoff.pack(source, archive, SOURCE, inputs, tier="release")
    # This expected value models the separate authenticated qualifier output;
    # its API/ZIP/upload-window and exact-output behavior is exercised by the
    # qualified_handoff fixture in test_linux_ci_handoff.py.
    proof = {
        "handoff_manifest_sha256": digest(archive / "source-build.json"),
        "handoff_producer_job": 300,
    }
    assert "dist" not in manifest["files"]
    assert not any(name.endswith(".tar.gz") for name in manifest["files"])
    assert manifest["portable_package"]["sha256"] == digest(
        packages / "application.tar.gz"
    )
    return packages, archive, proof


@pytest.mark.parametrize(
    "change",
    [
        "archive",
        "package",
        "source",
        "tier",
        "manifest-package",
        "missing",
        "checksum-sidecar",
        "metadata-sidecar",
        "package-with-valid-sidecars",
        "missing-proof",
        "wrong-job",
        "ambiguous-package",
        "symlink-manifest",
        "symlink-archive",
    ],
)
def test_linux_test_receipt_binds_separate_bytes_to_exact_qualified_compact_handoff(
    release_handoff, tmp_path, change
):
    import hashlib

    packages, archive, proof = release_handoff
    manifest_path = archive / "source-build.json"
    manifest = json.loads(manifest_path.read_text())
    package = packages / "application.tar.gz"
    if change == "archive":
        (archive / "source-build.tar.gz").write_bytes(b"different archive")
    elif change in ("package", "package-with-valid-sidecars"):
        package.write_bytes(b"different package")
        if change == "package-with-valid-sidecars":
            checksum = hashlib.sha256(package.read_bytes()).hexdigest()
            package.with_name(package.name + ".sha256").write_text(
                f"{checksum}  {package.name}\n"
            )
            metadata = package.with_name(package.name + ".build.json")
            record = json.loads(metadata.read_text())
            record["sha256"] = checksum
            metadata.write_text(json.dumps(record))
    elif change == "source":
        manifest["source"] = "b" * 40
    elif change == "tier":
        manifest["tier"] = "preview"
    elif change == "manifest-package":
        manifest["portable_package"]["sha256"] = "c" * 64
    elif change == "checksum-sidecar":
        checksum = package.with_name(package.name + ".sha256")
        checksum.write_text(
            checksum.read_text().upper().replace(package.name.upper(), package.name)
        )
    elif change == "metadata-sidecar":
        metadata = package.with_name(package.name + ".build.json")
        metadata.write_text(metadata.read_text() + "\n")
    elif change == "missing-proof":
        proof["handoff_manifest_sha256"] = ""
    elif change == "wrong-job":
        proof["handoff_producer_job"] = 301
    elif change == "ambiguous-package":
        (packages / "duplicate.tar.gz").write_bytes(package.read_bytes())
    elif change.startswith("symlink-"):
        path = (
            manifest_path
            if change == "symlink-manifest"
            else archive / "source-build.tar.gz"
        )
        moved = path.with_name("original-" + path.name)
        path.rename(moved)
        path.symlink_to(moved)
    if change in ("source", "tier", "manifest-package"):
        manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        acceptance.record_input(
            packages,
            SOURCE,
            tmp_path / "consumption.json",
            "linux-test",
            None if change == "missing" else archive,
            **proof,
        )
    assert not (tmp_path / "consumption.json").exists()


def test_linux_handoff_and_separate_portable_archive_create_one_byte_bound_receipt(
    release_handoff, tmp_path
):
    packages, archive, proof = release_handoff
    original = (packages / "application.tar.gz").read_bytes()
    assert (
        acceptance.record_input(
            packages,
            SOURCE,
            tmp_path / "consumption.json",
            "linux-test",
            archive,
            **proof,
        )["artifact_id"]
        == 200
    )
    assert (packages / "application.tar.gz").read_bytes() == original


@pytest.mark.parametrize(
    "change", ["missing", "symlink", "tier", "label", "gate", "ambiguous"]
)
def test_consumption_evidence_fails_before_writing_for_unqualified_inputs(
    release_input, tmp_path, change
):
    packages, qualification = release_input
    path = packages / "source-qualification.json"
    gate = "acceptance-deb"
    if change == "missing":
        path.unlink()
    elif change == "symlink":
        real = packages / "qualification.json"
        path.rename(real)
        path.symlink_to(real.name)
    elif change in ("tier", "label"):
        qualification["source_receipt"][change] = (
            "preview" if change == "tier" else "nightly.20261019.1"
        )
        path.write_text(json.dumps(qualification))
    elif change == "gate":
        gate = "untrusted-gate"
    elif change == "ambiguous":
        (packages / "second.tar.gz").write_bytes(
            (packages / "application.tar.gz").read_bytes()
        )
    output = tmp_path / "consumption.json"
    with pytest.raises(ValueError):
        acceptance.record_input(packages, SOURCE, output, gate)
    assert not output.exists()


def test_record_consumption_cli_uses_explicit_source_and_gate(
    release_input, tmp_path, monkeypatch
):
    packages, _ = release_input
    output = tmp_path / "cli/consumption.json"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_linux_acceptance.py",
            "--record-input",
            "--source",
            SOURCE,
            "--gate",
            "acceptance-cpu",
            "--packages",
            str(packages),
            "--output",
            str(output),
        ],
    )
    acceptance.main()
    assert json.loads(output.read_text())["consumer_run_attempt"] == 3


@pytest.mark.parametrize(
    "args", [[], ["--record-input"], ["--record-input", "--source", SOURCE]]
)
def test_consumption_cli_requires_its_explicit_identity(args, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["ci_linux_acceptance.py", *args])
    with pytest.raises(SystemExit) as error:
        acceptance.main()
    assert error.value.code == 2


def test_aggregate_cli_rejects_unclassified_selection(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["ci_linux_acceptance.py", "--check-gates"])
    monkeypatch.setenv("SELECTED", "maybe")
    with pytest.raises(ValueError, match="Malformed"):
        acceptance.main()


@pytest.mark.parametrize("label", ["", "nightly.20261019.3"])
def test_prepare_cli_keeps_original_bundle_and_reports_qualified_preview_version(
    producer, tmp_path, monkeypatch, label
):
    output = tmp_path / "outputs"
    destination = tmp_path / "portable-cli"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_linux_acceptance.py",
            "--source",
            SOURCE,
            "--packages",
            str(producer[0]),
            "--destination",
            str(destination),
            "--label",
            label,
        ],
    )
    acceptance.main()
    assert f"version=0.1.2{('~' + label) if label else ''}\n" in output.read_text()
    assert (destination / "open-foresight/executable").is_file()


@pytest.mark.parametrize("change", ["label", "ambiguous"])
def test_prepare_rejects_ambiguous_or_unqualified_preview_inputs(
    producer, tmp_path, change
):
    packages = producer[0]
    label = "invalid" if change == "label" else ""
    if change == "ambiguous":
        (packages / "duplicate.tar.gz").write_bytes(
            (packages / "application.tar.gz").read_bytes()
        )
    with pytest.raises(ValueError):
        acceptance.prepare(packages, tmp_path / "portable", SOURCE, label)


def test_unselected_aggregate_cli_requires_all_consumers_skipped(monkeypatch):
    monkeypatch.setenv("SELECTED", "false")
    monkeypatch.setenv(
        "NEEDS",
        json.dumps(
            {
                "changes": {"result": "success"},
                **{
                    name: {"result": "skipped"}
                    for name in (
                        "linux-build",
                        "linux-bundle",
                        "acceptance-cpu",
                        "acceptance-audio",
                        "acceptance-deb",
                    )
                },
            }
        ),
    )
    monkeypatch.setattr(sys, "argv", ["ci_linux_acceptance.py", "--check-gates"])
    acceptance.main()


def test_linux_test_uses_the_authenticated_qualifier_outputs_for_compact_evidence():
    steps = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"][
        "linux-test"
    ]["steps"]
    qualifier = next(
        step for step in steps if "ci_linux_handoff.py qualify" in step.get("run", "")
    )
    consumer = next(
        step
        for step in steps
        if "--record-input --gate linux-test" in step.get("run", "")
    )
    assert steps.index(qualifier) < steps.index(consumer)
    assert qualifier["id"] == "handoff-proof"
    assert (
        consumer["env"]["HANDOFF_MANIFEST_SHA256"]
        == "${{ steps.handoff-proof.outputs.manifest_sha256 }}"
    )
    assert (
        consumer["env"]["HANDOFF_PRODUCER_JOB"]
        == "${{ steps.handoff-proof.outputs.producer_job }}"
    )
    assert '--handoff-manifest-sha256 "$HANDOFF_MANIFEST_SHA256"' in consumer["run"]
    assert '--handoff-producer-job "$HANDOFF_PRODUCER_JOB"' in consumer["run"]
