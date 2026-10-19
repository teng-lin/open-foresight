"""Draft retries retain successful immutable bytes and select missing formats."""

import hashlib
import json
from pathlib import Path
from unittest.mock import patch

import pytest

from tools import release_upload as upload, release_inputs as inputs

SHA = "a" * 40


def package(tmp_path):
    path = tmp_path / "open-foresight_0.1.2-1_amd64.deb"
    path.write_bytes(b"retained native installer")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(f"{digest}  {path.name}\n")
    metadata = {"revision": SHA, "version": "0.1.2", "format": "deb", "sha256": digest}
    Path(str(path) + ".build.json").write_text(json.dumps(metadata))
    return path, metadata


def draft(paths):
    return {
        "draft": True,
        "tag_name": "v0.1.2",
        "target_commitish": SHA,
        "body": "<!-- foresight-package-release: 1 -->",
        "assets": [
            {
                "id": i + 1,
                "name": path.name,
                "size": path.stat().st_size,
                "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for i, path in enumerate(paths)
        ],
    }


def test_identical_draft_assets_are_retained_and_only_missing_files_are_uploaded(
    tmp_path,
):
    path, metadata = package(tmp_path)
    paths = sorted(tmp_path.iterdir())
    current = draft([path])
    with (
        patch.object(upload, "release_for_tag", return_value=current),
        patch.object(upload, "api", return_value={"sha": SHA}),
        patch.object(upload.subprocess, "run") as command,
    ):
        upload.upload("owner/repo", "v0.1.2", paths)
    arguments = command.call_args.args[0]
    assert arguments[:3] == ["gh", "release", "upload"]
    assert str(path) not in arguments
    assert "--clobber" not in arguments
    assert set(arguments[6:]) == {str(item) for item in paths if item != path}


@pytest.mark.parametrize("invalid", ["public", "source", "changed_bytes"])
def test_upload_never_replaces_conflicting_or_public_assets(tmp_path, invalid):
    path, metadata = package(tmp_path)
    current = draft([path])
    if invalid == "public":
        current["draft"] = False
    if invalid == "source":
        current["target_commitish"] = "b" * 40
    if invalid == "changed_bytes":
        current["assets"][0]["digest"] = "sha256:" + "0" * 64
    with (
        patch.object(upload, "release_for_tag", return_value=current),
        patch.object(upload, "api", return_value={"sha": SHA}),
        patch.object(upload.subprocess, "run") as command,
    ):
        with pytest.raises(ValueError):
            upload.upload("owner/repo", "v0.1.2", [path])
        command.assert_not_called()


def test_package_plan_retains_verified_deb_and_selects_only_missing_formats(tmp_path):
    path, metadata = package(tmp_path)
    current = draft(sorted(tmp_path.iterdir()))
    with (
        patch.object(inputs, "release_source", return_value=SHA),
        patch.object(inputs, "release_for_tag", return_value=current),
        patch.object(
            inputs,
            "api",
            return_value={"commit": {"committer": {"date": "2026-10-18T01:00:00Z"}}},
        ),
        patch.object(
            inputs.subprocess, "check_output", return_value=json.dumps(metadata)
        ),
    ):
        result = inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1")
        assert json.loads(result["formats"]) == ["rpm", "arch"]
        assert result["release"] == "1" and result["source"] == SHA
        assert (
            inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1", "deb")["formats"]
            == "[]"
        )
        with pytest.raises(ValueError, match="generation"):
            inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "2")
        metadata["revision"] = "b" * 40
        with patch.object(
            inputs.subprocess, "check_output", return_value=json.dumps(metadata)
        ):
            with pytest.raises(ValueError, match="another product"):
                inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1")
