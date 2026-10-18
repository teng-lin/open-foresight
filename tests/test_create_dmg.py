"""Shared preview/release DMG packaging binds sidecars to the resulting bytes."""

import hashlib
import json
from pathlib import Path
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
