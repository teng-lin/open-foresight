"""Shared preview/release DMG packaging binds sidecars to the resulting bytes."""

import hashlib
import json
from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest

from tools import create_dmg


def test_shared_dmg_sidecar_binds_bytes_source_version_architecture_and_build(tmp_path):
    app = tmp_path / "Open Foresight.app"
    app.mkdir()
    manifest = tmp_path / "app.manifest.json"
    identity = {
        "revision": "a" * 40,
        "architecture": "arm64",
        "version": "0.1.2",
        "build_number": 42,
    }
    manifest.write_text(json.dumps(identity))

    def run(arguments, **kwargs):
        if arguments[:2] == ["hdiutil", "create"]:
            Path(arguments[-1]).write_bytes(b"verified disk image")
        return subprocess.CompletedProcess(arguments, 0, "verified\n", "")

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        image = create_dmg.create(
            app, manifest, "Open-Foresight-0.1.2-macos-arm64.dmg", tmp_path / "dist"
        )
    metadata = json.loads(Path(str(image) + ".build.json").read_text())
    assert metadata == {
        "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
        "format": "dmg",
        "version": "0.1.2",
        "revision": "a" * 40,
        "arch": "arm64",
        "build_number": 42,
    }
    assert json.loads(Path(str(image) + ".manifest.json").read_text()) == identity


def test_invalid_dmg_application_identity_is_rejected_before_building(tmp_path):
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "revision": "main",
                "architecture": "arm64",
                "version": "0.1.2",
                "build_number": 42,
            }
        )
    )
    with patch.object(create_dmg.subprocess, "run") as run:
        with pytest.raises(ValueError, match="application build identity"):
            create_dmg.create(
                tmp_path / "App.app",
                manifest,
                "Open-Foresight-0.1.2-macos-arm64.dmg",
                tmp_path / "dist",
            )
        run.assert_not_called()


BUSY = "hdiutil: verify failed - Resource temporarily unavailable\n"


@pytest.fixture
def clock():
    class Clock:
        now = 0

        def advance(self, seconds):
            self.now += seconds

    clock = Clock()
    with patch.object(create_dmg.time, "monotonic", side_effect=lambda: clock.now):
        yield clock


def test_retry_rejects_changed_disk_image_bytes(tmp_path):
    image = tmp_path / "fixture.dmg"
    image.write_bytes(b"original")
    result = subprocess.CompletedProcess(["hdiutil"], 1, "", BUSY)
    with (
        patch.object(create_dmg.subprocess, "run", return_value=result) as run,
        patch.object(
            create_dmg.time,
            "sleep",
            side_effect=lambda _: image.write_bytes(b"changed"),
        ),
        pytest.raises(ValueError, match="DMG bytes changed"),
    ):
        create_dmg.verify_image(image)
    run.assert_called_once()


@pytest.mark.parametrize("output", [b"partial output\xff\n", "partial output\n", None])
def test_verification_timeout_preserves_partial_output_without_retry(
    tmp_path, capsys, output
):
    command = ["hdiutil", "verify", str(tmp_path / "existing.dmg")]
    timeout = subprocess.TimeoutExpired(command, 300, output=output, stderr=output)
    with (
        patch.object(create_dmg.subprocess, "run", side_effect=timeout) as run,
        patch.object(create_dmg.time, "sleep") as sleep,
        pytest.raises(subprocess.TimeoutExpired) as error,
    ):
        create_dmg.verify_image(tmp_path / "existing.dmg")
    assert error.value is timeout
    run.assert_called_once()
    sleep.assert_not_called()
    captured = capsys.readouterr()
    expected = output.decode(errors="replace") if isinstance(output, bytes) else output
    assert captured.out == (expected or "")
    assert captured.err == (expected or "")


@pytest.mark.parametrize("failures", [0, 1, 2, 3, 4, 14])
def test_verification_retries_only_transient_busy_and_preserves_output(
    tmp_path, capsys, failures, clock
):
    image = tmp_path / "existing.dmg"
    image.write_bytes(b"same image bytes")
    command = ["hdiutil", "verify", str(image)]
    results = [
        subprocess.CompletedProcess(command, 1, "busy attempt\n", BUSY)
    ] * failures
    results.append(subprocess.CompletedProcess(command, 0, "verified image\n", ""))
    with (
        patch.object(create_dmg.subprocess, "run", side_effect=results) as run,
        patch.object(create_dmg.time, "sleep", side_effect=clock.advance) as sleep,
    ):
        create_dmg.verify_image(image)
    assert run.call_count == failures + 1
    for attempt, call in enumerate(run.call_args_list):
        assert call.args == (command,)
        assert call.kwargs == {
            "capture_output": True,
            "text": True,
            "timeout": 300 if attempt == 0 else 30 - 2 * attempt,
        }
    assert sleep.call_args_list == [((2,),)] * failures
    output = capsys.readouterr()
    assert output.out == "busy attempt\n" * failures + "verified image\n"
    assert output.err.count(BUSY) == failures
    assert image.read_bytes() == b"same image bytes"


@pytest.mark.parametrize(
    ("diagnostic", "returncode", "attempts"),
    [
        (BUSY, 1, 15),
        (BUSY, -9, 1),
        ("hdiutil: verify failed - checksum mismatch\n", 1, 1),
        ("hdiutil: verify failed - image not recognized\n", 1, 1),
        ("other tool: Resource temporarily unavailable\n", 1, 1),
    ],
)
def test_failed_verification_never_recreates_image_or_writes_sidecars(
    tmp_path, capsys, diagnostic, returncode, attempts, clock
):
    app = tmp_path / "Open Foresight.app"
    app.mkdir()
    manifest = tmp_path / "app.manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "revision": "a" * 40,
                "architecture": "arm64",
                "version": "0.1.2",
                "build_number": 42,
            }
        )
    )
    commands = []

    def run(arguments, **kwargs):
        commands.append(arguments)
        if arguments[:2] == ["hdiutil", "create"]:
            Path(arguments[-1]).write_bytes(b"original image")
        if arguments[:2] == ["hdiutil", "verify"]:
            return subprocess.CompletedProcess(
                arguments, returncode, "failed output\n", diagnostic
            )
        return subprocess.CompletedProcess(arguments, 0, "", "")

    with (
        patch.object(create_dmg.subprocess, "run", side_effect=run),
        patch.object(create_dmg.time, "sleep", side_effect=clock.advance) as sleep,
        pytest.raises(subprocess.CalledProcessError) as error,
    ):
        create_dmg.create(
            app, manifest, "Open-Foresight-0.1.2-macos-arm64.dmg", tmp_path / "dist"
        )
    assert sum(cmd[:2] == ["hdiutil", "create"] for cmd in commands) == 1
    assert sum(cmd[:2] == ["hdiutil", "verify"] for cmd in commands) == attempts
    assert sleep.call_args_list == [((2,),)] * (
        15 if diagnostic == BUSY and returncode == 1 else 0
    )
    image = tmp_path / "dist/Open-Foresight-0.1.2-macos-arm64.dmg"
    assert image.read_bytes() == b"original image"
    assert sorted(path.name for path in image.parent.iterdir()) == [image.name]
    assert error.value.stdout == "failed output\n"
    assert error.value.stderr == diagnostic
    output = capsys.readouterr()
    assert output.out == "failed output\n" * attempts
    assert output.err.count(diagnostic) == attempts


def test_verification_bounds_recovery_including_command_time(tmp_path, clock):
    image = tmp_path / "fixture.dmg"
    image.write_bytes(b"original image")

    def run(command, **kwargs):
        clock.advance(29.5)
        return subprocess.CompletedProcess(command, 1, "locked image\n", BUSY)

    with (
        patch.object(create_dmg.subprocess, "run", side_effect=run) as verify,
        patch.object(create_dmg.time, "sleep", side_effect=clock.advance) as sleep,
        pytest.raises(subprocess.CalledProcessError) as error,
    ):
        create_dmg.verify_image(image)
    verify.assert_called_once()
    sleep.assert_called_once_with(0.5)
    assert clock.now == 30
    assert error.value.stdout == "locked image\n"
    assert error.value.stderr == BUSY


def test_verification_rejects_bytes_changed_during_successful_command(tmp_path):
    image = tmp_path / "fixture.dmg"
    image.write_bytes(b"original image")

    def run(command, **kwargs):
        image.write_bytes(b"changed image")
        return subprocess.CompletedProcess(command, 0, "verified image\n", "")

    with (
        patch.object(create_dmg.subprocess, "run", side_effect=run),
        pytest.raises(ValueError, match="DMG bytes changed during verification"),
    ):
        create_dmg.verify_image(image)
