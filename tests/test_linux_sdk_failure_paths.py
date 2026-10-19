"""Saved SDK images fail closed at OCI, Docker, and promotion boundaries."""

import hashlib
import io
import json
import subprocess
import sys
import tarfile
from unittest.mock import Mock

import pytest
from tools import linux_sdk_artifacts as sdk
from test_linux_sdk_artifacts import oci_archive, missing_docker_image


@pytest.mark.parametrize(
    "failure",
    [
        "index",
        "duplicate",
        "digest",
        "size",
        "children",
        "config",
        "layers",
        "metadata-kind",
        "empty",
    ],
)
def test_invalid_oci_inventory_cannot_be_loaded_as_original_image(tmp_path, failure):
    files = {}

    def blob(value):
        raw = json.dumps(value).encode()
        identity = "sha256:" + hashlib.sha256(raw).hexdigest()
        files["blobs/sha256/" + identity[7:]] = raw
        return {"digest": identity, "size": len(raw)}

    config = blob({"os": "linux", "architecture": "amd64"})
    document = {"config": config, "layers": []}
    if failure == "children":
        document = {"manifests": "untrusted"}
    elif failure == "config":
        document["config"] = None
    elif failure == "layers":
        document["layers"] = None
    target = blob(document)
    if failure == "digest":
        target["digest"] = "mutable:latest"
    elif failure == "size":
        target["size"] += 1
    index = {"manifests": [target]}
    if failure == "index":
        index["manifests"] = "not-a-list"
    elif failure == "empty":
        index["manifests"] = []
    files["index.json"] = json.dumps(index).encode()
    archive = tmp_path / "image.tar"
    with tarfile.open(archive, "w") as stream:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            if name == "index.json" and failure == "metadata-kind":
                member.type, member.size = tarfile.DIRTYPE, 0
            stream.addfile(member, io.BytesIO(data) if member.isfile() else None)
        if failure == "duplicate":
            stream.addfile(tarfile.TarInfo("index.json"))
    before = archive.read_bytes()
    with pytest.raises(ValueError):
        sdk.archive_manifests(archive, config["digest"])
    assert archive.read_bytes() == before


@pytest.mark.parametrize(
    "failure", ["all-missing", "candidate-daemon", "initial-bytes"]
)
def test_oci_fallback_only_accepts_exact_missing_image_diagnostic(
    tmp_path, monkeypatch, failure
):
    prefix = tmp_path / "prefix"
    original, manifest, _ = oci_archive(prefix)
    calls = []

    def inspect(image):
        calls.append(image)
        if image == original:
            error = missing_docker_image(image)
            if failure == "initial-bytes":
                error.output = error.output.encode()
            raise error
        if failure == "candidate-daemon":
            raise subprocess.CalledProcessError(
                1, "docker", output="daemon unavailable"
            )
        if failure == "all-missing":
            raise missing_docker_image(image)
        return image

    monkeypatch.setattr(sdk, "inspect", inspect)
    run = Mock()
    monkeypatch.setattr(sdk, "run", run)
    before = (prefix / "image.tar").read_bytes()
    if failure == "initial-bytes":
        assert sdk.load(prefix, "linux-sdk", "verified:local") == "verified:local"
        assert calls == [original, manifest]
        assert run.call_args.args[0] == [
            "docker",
            "image",
            "tag",
            manifest,
            "verified:local",
        ]
    else:
        expected = (
            ValueError if failure == "all-missing" else subprocess.CalledProcessError
        )
        with pytest.raises(expected):
            sdk.load(prefix, "linux-sdk", "verified:local")
        assert run.call_count == 1  # Load only; never publish or build.
    assert (prefix / "image.tar").read_bytes() == before


def test_sdk_subprocess_wrapper_checks_exit_and_timeout(monkeypatch):
    run = Mock()
    monkeypatch.setattr(sdk.subprocess, "run", run)
    sdk.run(["docker", "image", "load"], timeout=17)
    run.assert_called_once_with(["docker", "image", "load"], check=True, timeout=17)
    with pytest.raises(ValueError, match="Unknown Linux SDK"):
        sdk.local_tag("application")


@pytest.mark.parametrize(
    "failure", ["source-file", "source-link", "qualification-type"]
)
def test_invalid_promotion_source_preserves_destination_and_original(tmp_path, failure):
    source = tmp_path / "source"
    if failure == "source-file":
        source.write_bytes(b"original")
    else:
        source.mkdir()
        if failure == "source-link":
            link = tmp_path / "link"
            link.symlink_to(source)
            source = link
        else:
            (source / "source-qualification.json").write_text("[]")
    destination = tmp_path / "destination"
    with pytest.raises(ValueError):
        sdk.describe(
            destination, "linux-sdk", "ghcr.io/owner/sdk@sha256:" + "a" * 64, source
        )
    assert not destination.exists()
    assert source.exists()


@pytest.mark.parametrize(
    "arguments",
    [
        ["produce"],
        ["resolve"],
        ["promote", "--prefix", "PREFIX"],
        ["describe"],
        ["produce", "--load"],
    ],
)
def test_incomplete_cli_does_not_touch_docker(tmp_path, monkeypatch, arguments):
    monkeypatch.setattr(
        sys,
        "argv",
        ["sdk", *[str(tmp_path) if a == "PREFIX" else a for a in arguments]],
    )
    command = Mock(side_effect=AssertionError("Docker must not run"))
    monkeypatch.setattr(sdk, "run", command)
    with pytest.raises(SystemExit, match="2"):
        sdk.main()
    command.assert_not_called()


def test_resolve_without_ci_output_only_reports_verified_image(
    tmp_path, monkeypatch, capsys
):
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    sdk.write_outputs("ghcr.io/owner/sdk@sha256:" + "a" * 64)
    assert "Qualified SDK image:" in capsys.readouterr().out
