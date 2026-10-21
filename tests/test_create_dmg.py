"""Shared preview/release DMG packaging binds sidecars to the resulting bytes."""

import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest

from tools import create_dmg


@pytest.mark.parametrize("leaked_attachment", [False, True])
def test_shared_dmg_sidecar_binds_bytes_source_version_architecture_and_build(
    tmp_path, leaked_attachment
):
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

    commands = []

    def run(arguments, **kwargs):
        commands.append(arguments)
        if arguments == ["hdiutil", "info", "-plist"]:
            image = tmp_path / "dist/Open-Foresight-0.1.2-macos-arm64.dmg"
            return subprocess.CompletedProcess(
                arguments, 0, plistlib.dumps({"images": [attachment(image)]}), b""
            )
        if (
            leaked_attachment
            and arguments[:2] == ["hdiutil", "verify"]
            and not any(cmd[:2] == ["hdiutil", "detach"] for cmd in commands)
        ):
            return subprocess.CompletedProcess(arguments, 1, "", BUSY)
        if arguments[:2] == ["hdiutil", "create"]:
            Path(arguments[-1]).write_bytes(b"verified disk image")
        return subprocess.CompletedProcess(arguments, 0, "verified\n", "")

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        image = create_dmg.create(
            app, manifest, "Open-Foresight-0.1.2-macos-arm64.dmg", tmp_path / "dist"
        )
    assert [cmd for cmd in commands if cmd[:2] == ["hdiutil", "detach"]] == (
        [["hdiutil", "detach", "/dev/disk5"]] if leaked_attachment else []
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
        if arguments == ["hdiutil", "info", "-plist"]:
            return subprocess.CompletedProcess(
                arguments, 0, plistlib.dumps({"images": []}), b""
            )
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


@pytest.mark.parametrize(
    "failure", [None, OSError("missing lsof"), subprocess.TimeoutExpired("lsof", 10)]
)
def test_image_diagnostics_capture_lock_owners_without_hiding_failure(
    tmp_path, capsys, failure
):
    image = tmp_path / "existing.dmg"
    image.write_bytes(b"original image")

    def run(command, **kwargs):
        assert image.exists()
        assert kwargs["timeout"] == 10
        if failure:
            raise failure
        return subprocess.CompletedProcess(
            command, 0, "diskimages-helper holds image", "diagnostic stderr"
        )

    with patch.object(create_dmg.subprocess, "run", side_effect=run) as diagnostic:
        create_dmg.image_diagnostics(image)
    assert diagnostic.call_args_list[0].args[0] == ["/usr/sbin/lsof", str(image)]
    assert diagnostic.call_args_list[1].args[0] == ["hdiutil", "info"]
    output = capsys.readouterr().err
    assert (
        "Diagnostic unavailable" if failure else "diskimages-helper holds image"
    ) in output
    assert image.read_bytes() == b"original image"


def attachment(image, disk="/dev/disk5"):
    return {
        "image-path": str(image),
        "owner-uid": os.getuid(),
        "system-entities": [
            {"dev-entry": disk, "content-hint": "GUID_partition_scheme"},
            {"dev-entry": disk + "s1", "content-hint": "Apple_APFS"},
            {
                "dev-entry": "/dev/disk6",
                "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC",
            },
        ],
    }


@pytest.mark.parametrize("change_bytes", [False, True])
def test_new_image_recovery_detaches_only_owned_outer_device(tmp_path, change_bytes):
    image = tmp_path / "new.dmg"
    image.write_bytes(b"created image")
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[1] == "verify":
            busy = len(commands) == 1
            return subprocess.CompletedProcess(
                command, int(busy), "", BUSY if busy else ""
            )
        if command[1] == "info":
            return subprocess.CompletedProcess(
                command,
                0,
                plistlib.dumps(
                    {
                        "images": [
                            attachment(tmp_path / "unrelated.dmg", "/dev/disk9"),
                            attachment(image),
                        ]
                    }
                ),
                b"",
            )
        assert command == ["hdiutil", "detach", "/dev/disk5"]
        if change_bytes:
            image.write_bytes(b"changed during detach")
        return subprocess.CompletedProcess(command, 0, "detached\n", "")

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        if change_bytes:
            with pytest.raises(ValueError, match="DMG bytes changed"):
                create_dmg.verify_image(image, created_image=True)
        else:
            create_dmg.verify_image(image, created_image=True)
    assert [cmd for cmd in commands if cmd[1] == "detach"] == [
        ["hdiutil", "detach", "/dev/disk5"]
    ]
    assert sum(cmd[1] == "verify" for cmd in commands) == (1 if change_bytes else 2)


@pytest.mark.parametrize(
    "case",
    [
        "duplicate",
        "partition",
        "synthesized",
        "foreign-owner",
        "duplicate-guid",
        "detach-fails",
        "info-fails",
        "malformed",
    ],
)
def test_recovery_fails_closed_on_ambiguous_or_failed_cleanup(tmp_path, case, capsys):
    image = tmp_path / "new.dmg"
    image.write_bytes(b"created image")
    entry = attachment(image)
    entries = [entry]
    if case == "duplicate":
        entries.append(attachment(image))
    if case == "partition":
        entry["system-entities"][0]["dev-entry"] = "/dev/disk5s1"
    if case == "synthesized":
        entry["system-entities"].pop(0)
    if case == "duplicate-guid":
        entry["system-entities"].append(
            {"dev-entry": "/dev/disk8", "content-hint": "GUID_partition_scheme"}
        )
    if case == "foreign-owner":
        entry["owner-uid"] = os.getuid() + 1
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[1] == "verify":
            return subprocess.CompletedProcess(command, 1, "", BUSY)
        if command[1] == "info":
            return subprocess.CompletedProcess(
                command,
                int(case == "info-fails"),
                b"broken"
                if case == "malformed"
                else plistlib.dumps({"images": entries}),
                b"info diagnostic\n",
            )
        return subprocess.CompletedProcess(
            command, 1, "detach output\n", "detach failed\n"
        )

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        with pytest.raises(
            (ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException)
        ):
            create_dmg.verify_image(image, created_image=True)
    assert sum(cmd[1] == "detach" for cmd in commands) == int(case == "detach-fails")
    assert sum(cmd[1] == "verify" for cmd in commands) == 1
    assert image.read_bytes() == b"created image"
    assert "info diagnostic" in capsys.readouterr().err


@pytest.mark.parametrize("elapsed", [30, 29])
def test_attachment_discovery_and_detach_share_recovery_deadline(
    tmp_path, clock, elapsed
):
    image = tmp_path / "new.dmg"
    image.write_bytes(b"created image")
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[1] == "verify":
            clock.advance(elapsed)
            return subprocess.CompletedProcess(command, 1, "", BUSY)
        assert command == ["hdiutil", "info", "-plist"]
        assert kwargs["timeout"] == 1
        clock.advance(1)
        return subprocess.CompletedProcess(
            command, 0, plistlib.dumps({"images": [attachment(image)]}), b""
        )

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        with pytest.raises(subprocess.CalledProcessError):
            create_dmg.verify_image(image, created_image=True)
    assert sum(cmd[1] == "info" for cmd in commands) == int(elapsed == 29)
    assert not any(cmd[1] == "detach" for cmd in commands)


@pytest.mark.parametrize("phase", ["info", "detach"])
def test_attachment_timeout_preserves_partial_failure_output(tmp_path, phase, capsys):
    image = tmp_path / "new.dmg"
    image.write_bytes(b"created image")

    def run(command, **kwargs):
        if command[1] == phase:
            raise subprocess.TimeoutExpired(
                command, 10, output=b"partial output\n", stderr=b"partial error\n"
            )
        return subprocess.CompletedProcess(
            command, 0, plistlib.dumps({"images": [attachment(image)]}), b""
        )

    with patch.object(create_dmg.subprocess, "run", side_effect=run):
        with pytest.raises(subprocess.TimeoutExpired):
            create_dmg.detach_created_image(image)
    output = capsys.readouterr()
    assert "partial output" in output.out
    assert "partial error" in output.err
