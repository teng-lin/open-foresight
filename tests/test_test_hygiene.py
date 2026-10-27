"""Regression coverage for test-harness requirements and shared model metadata."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from model_pins import TABLE, model_pins, release_models  # noqa: E402
from service_ui_report import REQUIRED_EXPECTATIONS, verify_service_ui_report  # noqa: E402


@pytest.mark.parametrize(
    "requirement", [{"CI": "true"}, {"FORESIGHT_REQUIRE_DART_GATES": "1"}]
)
@pytest.mark.parametrize("missing", ["dart", "flutter"])
def test_build_fails_before_native_work_when_a_required_sdk_is_missing(
    tmp_path, requirement, missing
):
    for command in ["dirname", "uname"]:
        target = shutil.which(command)
        assert target
        (tmp_path / command).symlink_to(target)
    if missing == "flutter":
        dart = tmp_path / "dart"
        dart.write_text("#!/bin/sh\nexit 0\n")
        dart.chmod(0o700)
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "tools/build.sh")],
        env={**os.environ, **requirement, "PATH": str(tmp_path)},
        text=True,
        capture_output=True,
        timeout=5,
    )
    assert result.returncode != 0
    assert f"Required {missing} SDK is missing" in result.stderr


def test_shared_pin_table_drives_all_python_release_consumers():
    pins = model_pins()
    selected = release_models()
    assert len(pins) == 9
    assert selected["speech"][3] == pins["ggml-tiny.bin"]["sha256"]
    assert selected["generation"][3] == pins["gemma-4-E2B-it.litertlm"]["sha256"]
    for name, source in [
        ("test_macos_release_models", ROOT / "tools/test_macos_release_models.py"),
        ("test_packaged_model_runtime", ROOT / "tools/test_packaged_model_runtime.py"),
        ("smoke_installed", ROOT / "packaging/smoke_installed.py"),
    ]:
        spec = importlib.util.spec_from_file_location(name, source)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if name == "test_macos_release_models":
            assert module.MODELS == selected
        elif name == "smoke_installed":
            assert module.SPEECH_PIN == selected["speech"]
        else:
            assert module.GENERATION_SHA256 == selected["generation"][3]
            assert module.EMBEDDING_SHA256 == selected["embedding"][3]


@pytest.mark.parametrize("malformed", ["missing", "duplicate", "changed-json"])
def test_pin_parser_rejects_missing_or_ambiguous_fences(tmp_path, malformed):
    source = TABLE.read_text()
    if malformed == "missing":
        source = source.replace("// BEGIN FORESIGHT MODEL PINS", "// removed")
    elif malformed == "duplicate":
        source += "\n// BEGIN FORESIGHT MODEL PINS\n"
    else:
        source = source.replace("const modelPinsJson = r'''", "const other = r'''")
    table = tmp_path / "pins.dart"
    table.write_text(source)
    with pytest.raises(ValueError):
        model_pins(table)


@pytest.mark.parametrize("removed", sorted(REQUIRED_EXPECTATIONS))
def test_deleting_a_ui_expectation_fails_external_validation(removed):
    report = {
        "schema": 1,
        "expectations": [
            {"name": name, "actual": True, "expected": True, "passed": True}
            for name in sorted(REQUIRED_EXPECTATIONS)
        ],
    }
    verify_service_ui_report(report)
    mutated = copy.deepcopy(report)
    mutated["expectations"] = [
        item for item in mutated["expectations"] if item["name"] != removed
    ]
    with pytest.raises(ValueError, match=removed):
        verify_service_ui_report(mutated)
    with pytest.raises(ValueError):
        verify_service_ui_report({name: True for name in REQUIRED_EXPECTATIONS})


def test_repeated_ui_protocol_observations_preserve_unique_semantic_checks():
    observations = [
        {"name": name, "actual": True, "expected": True, "passed": True}
        for name in sorted(REQUIRED_EXPECTATIONS)
    ]
    protocol = next(item for item in observations if item["name"] == "mcp-envelope")
    observations.append(dict(protocol))
    report = {"schema": 1, "expectations": observations}
    verify_service_ui_report(report)
    semantic = next(
        item for item in observations if item["name"] == "transcript_persisted"
    )
    observations.append(dict(semantic))
    with pytest.raises(ValueError, match="transcript_persisted"):
        verify_service_ui_report(report)


def verify_python_collection(root, collected):
    """Require an explicit, reasoned exception for each uncollected module."""
    import configparser
    import json

    config = configparser.ConfigParser()
    config.read(root / "pytest.ini")
    assert config["pytest"]["testpaths"].split() == ["tests"]
    exclusions = json.loads((root / "pytest-exclusions.json").read_text())
    ignored = config["pytest"]["norecursedirs"].split()
    ignored += [
        arg.removeprefix("--ignore=")
        for arg in config["pytest"].get("addopts", "").split()
        if arg.startswith("--ignore=")
    ]
    modules = {
        str(path.relative_to(root)) for path in (root / "tests").rglob("test_*.py")
    }
    assert all(
        path in modules and reason.strip() for path, reason in exclusions.items()
    )
    assert all(
        any(Path(path).is_relative_to(folder) for folder in ignored)
        for path in exclusions
    )
    missing = modules - collected - exclusions.keys()
    assert not missing, (
        f"Uncollected Python tests need an explicit reason: {sorted(missing)}"
    )


def test_every_python_module_is_collected_or_explicitly_excluded(request):
    # Explicit targeted runs intentionally collect fewer modules. Check the
    # complete discovery invariant during the default suite only.
    if request.config.args != ["tests"]:
        return
    collected = {
        str(Path(item.path).relative_to(ROOT)) for item in request.session.items
    }
    reporter = request.config.pluginmanager.getplugin("terminalreporter")
    collected.update(
        str(Path(report.fspath)) for report in reporter.stats.get("skipped", [])
    )
    verify_python_collection(ROOT, collected)


def test_collection_guard_rejects_a_new_uncollected_module(tmp_path):
    import json

    (tmp_path / "tests/integration").mkdir(parents=True)
    (tmp_path / "pytest.ini").write_text(
        "[pytest]\ntestpaths = tests\nnorecursedirs = tests/integration\n"
    )
    (tmp_path / "pytest-exclusions.json").write_text(json.dumps({}))
    (tmp_path / "tests/integration/test_new.py").write_text("def test_new(): pass\n")
    with pytest.raises(AssertionError, match="test_new.py"):
        verify_python_collection(tmp_path, set())


def test_stale_python_cache_fails_before_cmake_or_native_work(tmp_path):
    cache = tmp_path / "build/CMakeCache.txt"
    cache.parent.mkdir()
    cache.write_text("Python3_EXECUTABLE:FILEPATH=/definitely-missing/old-python\n")
    result = subprocess.run(
        ["bash", str(ROOT / "tools/build.sh")],
        env={
            **os.environ,
            "CI": "false",
            "FORESIGHT_REQUIRE_DART_GATES": "0",
            "FORESIGHT_BUILD_DIR": str(cache.parent),
            "FORESIGHT_PYTHON": sys.executable,
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0
    assert "Cached Python interpreter no longer exists" in result.stderr
    assert "native configure" not in result.stdout


def _load_model_probe(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _selected_model_parent(tmp_path, monkeypatch, selected):
    monkeypatch.delenv("TMPDIR", raising=False)
    monkeypatch.delenv("FORESIGHT_TEST_TEMP_ROOT", raising=False)
    if selected == "default":
        return Path("/var/tmp").resolve()
    parent = tmp_path / "private"
    parent.mkdir(mode=0o700)
    alias = tmp_path / "alias"
    alias.symlink_to(parent, target_is_directory=True)
    monkeypatch.setenv(selected, str(alias))
    if selected == "FORESIGHT_TEST_TEMP_ROOT":
        monkeypatch.setenv("TMPDIR", str(tmp_path / "invalid-fallback"))
    return parent.resolve()


@pytest.mark.parametrize("selected", ["default", "TMPDIR", "FORESIGHT_TEST_TEMP_ROOT"])
@pytest.mark.parametrize("speech", ["success", "exit", "text"])
def test_release_model_probe_owns_private_speech_scratch_and_failure_report(
    tmp_path, monkeypatch, selected, speech
):
    module = _load_model_probe("test_macos_release_models")
    parent = _selected_model_parent(tmp_path, monkeypatch, selected)
    models, output = tmp_path / "models", tmp_path / "reports"
    models.mkdir()
    monkeypatch.setattr(
        module,
        "runtime_paths",
        lambda app: {"FORESIGHT_WHISPER_RUNTIME": tmp_path / "whisper"},
    )
    downloads = []

    def download(url, destination, checksum):
        downloads.append((url, checksum))
        destination.write_bytes(b"controlled fixture")

    monkeypatch.setattr(module, "download", download)
    commands, scratch = [], []

    def run(command, **kwargs):
        commands.append(command)
        if "-f" not in command:
            assert "test_packaged_model_runtime.py" in command[1]
            assert command[command.index("--backend") + 1] == "cpu"
            assert kwargs["timeout"] == 300 and kwargs["check"] is True
            return subprocess.CompletedProcess(command, 0)
        env = kwargs["env"]
        directory = Path(env["HOME"])
        scratch.append(directory)
        assert directory == directory.resolve() and directory.parent == parent
        assert directory.stat().st_mode & 0o077 == 0
        assert env["TMPDIR"] == env["FORESIGHT_TEST_TEMP_ROOT"] == str(directory)
        assert "--no-gpu" in command and kwargs["timeout"] == 180
        assert kwargs["cwd"] == "/"
        return subprocess.CompletedProcess(
            command,
            int(speech == "exit"),
            "ask not what your country" if speech != "text" else "wrong phrase",
            "retained stderr",
        )

    monkeypatch.setattr(module.subprocess, "run", run)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "probe",
            str(tmp_path / "app"),
            "--models",
            str(models),
            "--output",
            str(output),
        ],
    )
    if speech == "success":
        module.main()
    else:
        with pytest.raises(RuntimeError, match="public JFK"):
            module.main()
    assert len(commands) == 2 and len(downloads) == len(module.MODELS) == 3
    assert {checksum for _, checksum in downloads} == {
        value[3] for value in module.MODELS.values()
    }
    assert scratch and not scratch[0].exists()
    report = json.loads((output / "speech.json").read_text())
    assert report["stderr"] == "retained stderr"
    assert report["exit_code"] == int(speech == "exit")


@pytest.mark.parametrize("selected", ["default", "TMPDIR", "FORESIGHT_TEST_TEMP_ROOT"])
@pytest.mark.parametrize("failure", [None, "embedding", "generation"])
def test_packaged_model_probe_owns_canonical_scratch_on_success_and_failure(
    tmp_path, monkeypatch, selected, failure
):
    module = _load_model_probe("test_packaged_model_runtime")
    parent = _selected_model_parent(tmp_path, monkeypatch, selected)
    resources = tmp_path / "Fixture.app/Contents/Resources"
    resources.mkdir(parents=True)
    config = {
        "FORESIGHT_LITERT_RUNNER": "model",
        "FORESIGHT_MODEL_WORKER": "model",
        "FORESIGHT_LITERT_LIBRARY": "library",
    }
    (resources / "runtime.json").write_text(json.dumps(config))
    for name in ("model", "library"):
        (resources / name).write_bytes(b"fixture")
    for name in ("generation", "embedding"):
        (tmp_path / name).write_bytes(b"fixture model")
    monkeypatch.setattr(
        module,
        "digest",
        lambda path: (
            module.GENERATION_SHA256
            if path.name == "generation"
            else module.EMBEDDING_SHA256
        ),
    )
    observed = []

    def probe(kind):
        def execute(worker, model, backend, env, cwd, output, timeout):
            root = Path(env["TMPDIR"])
            observed.append((kind, root))
            assert root == root.resolve() and root.parent == parent
            assert root.stat().st_mode & 0o077 == 0
            assert env["FORESIGHT_TEST_TEMP_ROOT"] == str(root)
            assert Path(env["HOME"]).parent == root and cwd.parent == root
            assert (cwd / "litert_lm.py").is_file()
            assert backend == "cpu" and timeout == 600
            if failure == kind:
                raise RuntimeError(kind + " refused")
            return {"passed": True}

        return execute

    monkeypatch.setattr(module, "embedding_probe", probe("embedding"))
    monkeypatch.setattr(module, "generation_probe", probe("generation"))
    output = tmp_path / "reports"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "probe",
            "--bundle",
            str(resources.parent.parent),
            "--generation",
            str(tmp_path / "generation"),
            "--embedding",
            str(tmp_path / "embedding"),
            "--backend",
            "cpu",
            "--output",
            str(output),
        ],
    )
    if failure:
        with pytest.raises(RuntimeError, match=failure + " refused"):
            module.main()
    else:
        module.main()
    assert [kind for kind, _ in observed] == (
        ["embedding"] if failure == "embedding" else ["embedding", "generation"]
    )
    assert all(not root.exists() for _, root in observed)
    report = json.loads((output / "report.json").read_text())
    assert report["status"] == ("failed" if failure else "passed")
    if failure:
        assert report["error"] == failure + " refused"
