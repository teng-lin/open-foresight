"""The opt-in local installer verifies tiny pinned models at the build boundary."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from unittest.mock import Mock

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("failure", [False, True])
def test_local_setup_checks_download_hash_reuses_models_and_records_runtime_pin(
    tmp_path, monkeypatch, failure
):
    spec = importlib.util.spec_from_file_location(
        "local_setup_under_test", ROOT / "native/setup_models.py"
    )
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    config = tmp_path / "recipe/model_registry.json"
    config.parent.mkdir()
    content = b"pinned fixture model"
    registry = {
        kind: {
            "id": kind,
            "file": kind + ".model",
            "sha256": hashlib.sha256(content).hexdigest(),
            "download": "https://example.invalid/" + kind,
            "runtime_repository": "https://example.invalid/runtime",
            "runtime_revision": "a" * 40,
            "executable": "generation-cli" if kind == "generation" else "speech-cli",
            "effective_capabilities": [kind],
        }
        for kind in ("generation", "speech")
    }
    config.write_text(json.dumps(registry))
    monkeypatch.setattr(setup, "__file__", str(config.with_name("setup_models.py")))
    root = tmp_path / "local models"
    opening = Mock(
        side_effect=lambda *a, **kw: io.BytesIO(b"corrupt" if failure else content)
    )
    monkeypatch.setattr(setup.urllib.request, "urlopen", opening)
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[:2] == ["git", "init"]:
            Path(command[-1]).mkdir()
        if command[:2] == ["cmake", "--build"]:
            target = command[command.index("--target") + 1]
            build = Path(command[2])
            (build / "bin").mkdir(parents=True)
            (build / "bin" / target).write_bytes(b"runtime")

    monkeypatch.setattr(setup.subprocess, "run", run)
    monkeypatch.setattr(sys, "argv", ["setup", "--directory", str(root), "--jobs", "2"])
    if failure:
        with pytest.raises(RuntimeError, match="digest mismatch"):
            setup.main()
        assert not list(root.glob("*.partial"))
        assert not (root / "installed.json").exists()
        assert not commands
    else:
        setup.main()
        receipt = json.loads((root / "installed.json").read_text())
        assert set(receipt) == {"generation", "speech"}
        for entry in receipt.values():
            assert entry["sha256"] == hashlib.sha256(content).hexdigest()
            assert entry["runtime_revision"] == "a" * 40
            assert Path(entry["model"]).read_bytes() == content
            assert Path(entry["runtime"]).read_bytes() == b"runtime"
        assert all(call.kwargs["timeout"] == 120 for call in opening.call_args_list)
        # Reusing models does not redownload them. Existing native build trees
        # stay available to the incremental CMake invocation.
        for kind in registry:
            build = root / (kind + "-runtime-source/build/bin")
            for runtime in build.iterdir():
                runtime.unlink()
            build.rmdir()
        setup.main()
        assert opening.call_count == 2
        assert sum(command[:2] == ["git", "init"] for command in commands) == 2
