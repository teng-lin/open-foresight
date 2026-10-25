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


@pytest.fixture
def signed_dmg(tmp_path, monkeypatch):
    app = tmp_path / "Open Foresight.app"
    app.mkdir()
    manifest = tmp_path / "app.manifest.json"
    metadata = {
        "revision": "a" * 40,
        "architecture": "arm64",
        "version": "0.1.2",
        "build_number": 42,
        "signing": "developer-id",
        "notarized": True,
    }
    manifest.write_text(json.dumps(metadata))
    commands = []
    state = {"status": "Accepted", "app_team": "ABCDEFGHIJ", "dmg_team": "ABCDEFGHIJ"}

    def run(arguments, **kwargs):
        commands.append(arguments)
        if arguments[:2] == ["hdiutil", "create"]:
            Path(arguments[-1]).write_bytes(b"disk image")
        if arguments[:2] == ["codesign", "-dv"]:
            team = state["app_team" if Path(arguments[-1]) == app else "dmg_team"]
            details = f"Authority=Developer ID Application: Example ({team})\nTeamIdentifier={team}\n"
            return subprocess.CompletedProcess(arguments, 0, "", details)
        if arguments[:2] == ["codesign", "--force"]:
            Path(arguments[-1]).write_bytes(b"signed disk image")
        if arguments[:3] == ["xcrun", "notarytool", "submit"]:
            assert kwargs["timeout"] == 3600
            return subprocess.CompletedProcess(
                arguments,
                0,
                json.dumps({"status": state["status"], "id": "submission-id"}),
                "",
            )
        if arguments[:3] == ["xcrun", "notarytool", "log"]:
            Path(arguments[-1]).write_text('{"issues": ["rejected fixture"]}')
        if arguments[:3] == ["xcrun", "stapler", "staple"]:
            Path(arguments[-1]).write_bytes(b"signed and stapled disk image")
        return subprocess.CompletedProcess(arguments, 0, "", "")

    monkeypatch.setattr(create_dmg.subprocess, "run", run)

    def create(**options):
        return create_dmg.create(
            app,
            manifest,
            "Open-Foresight-0.1.2-macos-arm64.dmg",
            tmp_path / "dist",
            **(
                {
                    "identity": "Developer ID Application: Example (ABCDEFGHIJ)",
                    "notary_profile": "release",
                }
                | options
            ),
        )

    return create, commands, state, manifest


def test_signed_dmg_hashes_final_stapled_bytes_after_gatekeeper_acceptance(signed_dmg):
    create, commands, _, manifest = signed_dmg
    image = create()
    assert image.read_bytes() == b"signed and stapled disk image"
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    assert json.loads(Path(str(image) + ".build.json").read_text())["sha256"] == digest
    assert Path(str(image) + ".sha256").read_text() == f"{digest}  {image.name}\n"
    assert Path(str(image) + ".manifest.json").read_bytes() == manifest.read_bytes()
    assert (
        json.loads(Path(str(image) + ".notary.json").read_text())["status"]
        == "Accepted"
    )
    assert commands[-3:] == [
        ["xcrun", "stapler", "staple", str(image)],
        ["xcrun", "stapler", "validate", str(image)],
        [
            "spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "--verbose=2",
            str(image),
        ],
    ]
    assert commands.index(
        ["xcrun", "stapler", "validate", str(manifest.parent / "Open Foresight.app")]
    ) < next(
        i for i, command in enumerate(commands) if command[:2] == ["hdiutil", "create"]
    )


@pytest.mark.parametrize(
    "options",
    [
        {"identity": None},
        {"notary_profile": None},
        {"identity": "-"},
        {"identity": "", "notary_profile": ""},
    ],
)
def test_signed_dmg_requires_identity_and_notary_profile_together(signed_dmg, options):
    create, commands, _, _ = signed_dmg
    with pytest.raises(ValueError, match="require both"):
        create(**options)
    assert not commands


@pytest.mark.parametrize(
    "field,value", [("signing", "ad-hoc-development"), ("notarized", False)]
)
def test_signed_dmg_rejects_unnotarized_or_adhoc_app(signed_dmg, field, value):
    create, commands, _, manifest = signed_dmg
    metadata = json.loads(manifest.read_text())
    metadata[field] = value
    manifest.write_text(json.dumps(metadata))
    with pytest.raises(ValueError, match="notarized application"):
        create()
    assert not any(command[:2] == ["hdiutil", "create"] for command in commands)


@pytest.mark.parametrize(
    "field,team", [("app_team", "not-a-team"), ("dmg_team", "ZYXWVUTSRQ")]
)
def test_signed_dmg_rejects_invalid_or_mismatched_team(signed_dmg, field, team):
    create, _, state, manifest = signed_dmg
    state[field] = team
    with pytest.raises(ValueError, match="signature required|teams differ"):
        create()
    assert not list(manifest.parent.glob("dist/*.sha256"))


def test_rejected_dmg_retains_notary_response_and_log_without_success_sidecars(
    signed_dmg,
):
    create, _, state, manifest = signed_dmg
    state["status"] = "Invalid"
    with pytest.raises(ValueError, match="DMG notarization failed"):
        create()
    image = manifest.parent / "dist/Open-Foresight-0.1.2-macos-arm64.dmg"
    assert (
        json.loads(Path(str(image) + ".notary.json").read_text())["id"]
        == "submission-id"
    )
    assert "rejected fixture" in Path(str(image) + ".notary.log.json").read_text()
    assert not Path(str(image) + ".build.json").exists()
    assert not Path(str(image) + ".sha256").exists()


@pytest.mark.parametrize("failure", ["sign", "submit", "staple", "validate", "assess"])
def test_failed_dmg_signing_does_not_write_success_sidecars(
    signed_dmg, monkeypatch, failure
):
    create, _, _, manifest = signed_dmg
    original = create_dmg.subprocess.run

    def run(arguments, **kwargs):
        is_image = any(str(argument).endswith(".dmg") for argument in arguments)
        should_fail = (
            (failure == "sign" and arguments[:2] == ["codesign", "--force"])
            or (
                failure == "submit"
                and arguments[:3] == ["xcrun", "notarytool", "submit"]
            )
            or (
                failure in ("staple", "validate")
                and arguments[:3] == ["xcrun", "stapler", failure]
            )
            or (failure == "assess" and arguments[0] == "spctl")
        )
        if is_image and should_fail:
            return subprocess.CompletedProcess(
                arguments, 1, "partial signing output", "signing failed"
            )
        return original(arguments, **kwargs)

    monkeypatch.setattr(create_dmg.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError) as error:
        create()
    assert error.value.output == "partial signing output"
    assert error.value.stderr == "signing failed"
    assert not list(manifest.parent.glob("dist/*.sha256"))
    assert not list(manifest.parent.glob("dist/*.build.json"))


def test_signing_timeout_preserves_partial_output(capsys, monkeypatch):
    timeout = subprocess.TimeoutExpired(
        ["codesign"], 300, output=b"partial\n", stderr=b"failed\n"
    )

    def run(*args, **kwargs):
        raise timeout

    monkeypatch.setattr(create_dmg.subprocess, "run", run)
    with pytest.raises(subprocess.TimeoutExpired):
        create_dmg.signing_command(["codesign"])
    output = capsys.readouterr()
    assert output.out == "partial\n"
    assert output.err == "failed\n"


@pytest.mark.parametrize("log_failure", [False, True])
def test_nonzero_notary_rejection_retains_response_and_primary_failure(
    signed_dmg, monkeypatch, log_failure, capsys
):
    create, _, _, manifest = signed_dmg
    original = create_dmg.subprocess.run
    response = json.dumps({"status": "Invalid", "id": "rejected-id"})

    def run(arguments, **kwargs):
        if arguments[:3] == ["xcrun", "notarytool", "submit"]:
            return subprocess.CompletedProcess(
                arguments, 69, response, "notary rejected"
            )
        if arguments[:3] == ["xcrun", "notarytool", "log"] and log_failure:
            return subprocess.CompletedProcess(arguments, 1, "", "log unavailable")
        return original(arguments, **kwargs)

    monkeypatch.setattr(create_dmg.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError) as error:
        create()
    assert error.value.returncode == 69
    assert error.value.output == response
    image = manifest.parent / "dist/Open-Foresight-0.1.2-macos-arm64.dmg"
    assert Path(str(image) + ".notary.json").read_text() == response
    if log_failure:
        assert "log unavailable" in capsys.readouterr().err
    else:
        assert Path(str(image) + ".notary.log.json").is_file()
    assert not Path(str(image) + ".sha256").exists()


def test_development_certificate_is_rejected_even_with_team_identifier(monkeypatch):
    monkeypatch.setattr(
        create_dmg.subprocess,
        "run",
        lambda arguments, **kwargs: subprocess.CompletedProcess(
            arguments,
            0,
            "",
            "Authority=Apple Development: Example\nTeamIdentifier=ABCDEFGHIJ\n",
        ),
    )
    with pytest.raises(ValueError, match="Developer ID Application signature required"):
        create_dmg.developer_id_team(Path("App.app"))


def test_cli_forwards_signing_options(signed_dmg, monkeypatch):
    _, _, _, manifest = signed_dmg
    monkeypatch.setattr(
        create_dmg.sys,
        "argv",
        [
            "create_dmg.py",
            "--app",
            str(manifest.parent / "Open Foresight.app"),
            "--manifest",
            str(manifest),
            "--name",
            "Open-Foresight-0.1.2-macos-arm64.dmg",
            "--output",
            str(manifest.parent / "dist"),
            "--identity",
            "Developer ID Application: Example (ABCDEFGHIJ)",
            "--notary-profile",
            "release",
        ],
    )
    create_dmg.main()
    assert list(manifest.parent.glob("dist/*.sha256"))


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
