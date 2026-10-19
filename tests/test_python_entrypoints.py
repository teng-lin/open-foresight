"""Every offline argparse entrypoint must advertise help without doing work."""

import ast
from pathlib import Path
import runpy
import sys
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]


def entrypoints():
    result = []
    for directory in ("tools", "packaging", "native"):
        for path in sorted((ROOT / directory).rglob("*.py")):
            if path.name.startswith("test_"):
                continue
            tree = ast.parse(path.read_text())
            if any(
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "ArgumentParser"
                for node in ast.walk(tree)
            ):
                result.append(str(path.relative_to(ROOT)))
    return result


@pytest.mark.parametrize("relative", entrypoints())
def test_python_entrypoint_help_is_offline_and_successful(
    relative, monkeypatch, capsys
):
    # Loading the diagnostic tokenizer is optional; --help must not construct it.
    tokenizer = SimpleNamespace(
        SentencePieceProcessor=lambda **kw: pytest.fail("help constructed a tokenizer")
    )
    monkeypatch.setitem(sys.modules, "sentencepiece", tokenizer)
    monkeypatch.syspath_prepend(str(ROOT / "tools"))
    monkeypatch.syspath_prepend(str(ROOT / "packaging"))
    monkeypatch.setattr(sys, "argv", [relative, "--help"])
    import subprocess
    import urllib.request

    def unexpected(*args, **kwargs):
        pytest.fail("--help launched a process or opened the network")

    monkeypatch.setattr(subprocess, "run", unexpected)
    monkeypatch.setattr(subprocess, "Popen", unexpected)
    monkeypatch.setattr(subprocess, "check_output", unexpected)
    monkeypatch.setattr(urllib.request, "urlopen", unexpected)
    # The oracle's CLI sets a private umask before parsing. Keep the test host's
    # process settings intact while verifying its parser.
    import os

    monkeypatch.setattr(os, "umask", lambda mode: 0o022)
    with pytest.raises(SystemExit) as error:
        runpy.run_path(str(ROOT / relative), run_name="__main__")
    assert error.value.code == 0
    output = capsys.readouterr()
    assert "usage:" in output.out
    assert "--help" in output.out
    assert not output.err
