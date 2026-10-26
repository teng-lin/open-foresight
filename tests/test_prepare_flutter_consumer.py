"""Keep app packages intact while making sealed SDK tooling usable offline."""

import copy
import importlib.util
import json
from pathlib import Path
import stat
import sys
from unittest.mock import Mock

import pytest

spec = importlib.util.spec_from_file_location(
    "flutter_consumer", Path(__file__).parents[1] / "tools/prepare_flutter_consumer.py"
)
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


@pytest.fixture
def graph(tmp_path):
    workspace, flutter, cache = [
        tmp_path / name for name in ("source", "flutter", "sdk-cache")
    ]
    (workspace / "build").mkdir(parents=True)
    app = workspace / ".pub-cache/original"
    app.parent.mkdir()
    app.write_bytes(b"original qualified app cache")
    package = cache / "hosted/pub.dev/example-1.0.0"
    package.mkdir(parents=True)
    (package / "code.dart").write_bytes(b"verified SDK public tool package")
    config = flutter / "packages/flutter_tools/.dart_tool/package_config.json"
    config.parent.mkdir(parents=True)
    lock = config.parent.parent / "pubspec.lock"
    lock.write_bytes(b"original locked versions")
    record = {
        "configVersion": 2,
        "generatorVersion": "3.9.2",
        "packages": [
            {"name": "example", "rootUri": package.as_uri(), "languageVersion": "3.0"},
            {"name": "flutter_tools", "rootUri": "../", "languageVersion": "3.0"},
        ],
    }
    config.write_text(json.dumps(record))
    config.chmod(0o644)
    return workspace, flutter, cache, config, record, package, app, lock


def test_only_sdk_tool_root_uri_moves_to_distinct_workspace_cache(graph):
    workspace, flutter, cache, config, record, package, app, lock = graph
    assert consumer.prepare(workspace, flutter, source_cache=cache) == 1
    target = workspace / "build/.flutter-tool-pub/hosted/pub.dev/example-1.0.0"
    expected = copy.deepcopy(record)
    expected["packages"][0]["rootUri"] = target.as_uri()
    assert json.loads(config.read_text()) == expected
    assert stat.S_IMODE(config.stat().st_mode) == 0o644
    assert (target / "code.dart").read_bytes() == (package / "code.dart").read_bytes()
    assert app.read_bytes() == b"original qualified app cache"
    assert lock.read_bytes() == b"original locked versions"


@pytest.mark.parametrize(
    "attack", ["remote", "outside", "duplicate", "empty", "schema", "existing", "link"]
)
def test_unqualified_cache_metadata_refuses_without_rewriting_sdk_graph(
    graph, attack, tmp_path
):
    workspace, flutter, cache, config, record, package, app, lock = graph
    if attack == "remote":
        record["packages"][0]["rootUri"] = "https://example.invalid/package"
    elif attack == "outside":
        record["packages"][0]["rootUri"] = tmp_path.as_uri()
    elif attack == "duplicate":
        record["packages"].append(record["packages"][0])
    elif attack == "empty":
        record["packages"] = record["packages"][1:]
    elif attack == "schema":
        record["configVersion"] = 1
    elif attack == "existing":
        (workspace / "build/.flutter-tool-pub").mkdir()
    elif attack == "link":
        (package / "link").symlink_to(app)
    config.write_text(json.dumps(record))
    before = config.read_bytes()
    with pytest.raises(ValueError):
        consumer.prepare(workspace, flutter, source_cache=cache)
    assert config.read_bytes() == before
    assert app.read_bytes() == b"original qualified app cache"
    assert lock.read_bytes() == b"original locked versions"


def test_workspace_symlink_is_refused(graph, tmp_path):
    workspace, flutter, cache, *_ = graph
    alias = tmp_path / "alias"
    alias.symlink_to(workspace, target_is_directory=True)
    with pytest.raises(ValueError, match="physical"):
        consumer.prepare(alias, flutter, source_cache=cache)


def test_cli_prepares_before_executing_the_identity_wrapper(monkeypatch, graph):
    workspace, flutter, *_ = graph
    prepare = Mock(return_value=1)
    execute = Mock()
    monkeypatch.setattr(consumer, "prepare", prepare)
    monkeypatch.setattr(consumer.os, "execvpe", execute)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "prepare",
            "--workspace",
            str(workspace),
            "--flutter-root",
            str(flutter),
            "--",
            "python3",
            "/run-ci-user.py",
        ],
    )
    consumer.main()
    prepare.assert_called_once_with(workspace, flutter)
    execute.assert_called_once_with(
        "python3", ["python3", "/run-ci-user.py"], consumer.os.environ
    )


def test_cli_refuses_missing_identity_wrapper(monkeypatch, graph):
    workspace, flutter, *_ = graph
    monkeypatch.setattr(
        sys,
        "argv",
        ["prepare", "--workspace", str(workspace), "--flutter-root", str(flutter)],
    )
    with pytest.raises(SystemExit) as error:
        consumer.main()
    assert error.value.code == 2
