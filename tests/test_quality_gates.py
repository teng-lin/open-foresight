"""Quality gates reject unsafe execution and optimization-independent hash failures."""

import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import pytest
from unittest.mock import patch

from tools.check_subprocess_timeouts import missing_timeouts
from tools.build_macos_sdk import run as build_command
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def test_timeout_gate_handles_aliases_and_rejects_unbounded_values():
    assert missing_timeouts('import subprocess as sp\nsp.run(["git"])') == [2]
    assert missing_timeouts(
        'from subprocess import check_output as output\noutput(["git"], timeout=None)'
    ) == [2]
    assert missing_timeouts(
        'import subprocess\nsubprocess.call(["git"], timeout=0)'
    ) == [2]
    assert not missing_timeouts(
        'import subprocess\nsubprocess.run(["git"], timeout=30)'
    )


def test_fixture_download_has_network_timeout_and_checks_existing_hash(
    tmp_path, monkeypatch
):
    monkeypatch.syspath_prepend(str(ROOT / "tools"))
    spec = importlib.util.spec_from_file_location(
        "embedding_fixture", ROOT / "tools/download_embedding_fixture.py"
    )
    assert spec is not None and spec.loader is not None
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    content = b"verified fixture"
    checksum = hashlib.sha256(content).hexdigest()
    destination = tmp_path / "download"
    with (
        patch.object(
            fixture,
            "MODELS",
            {"embedding": ("repo", "revision", "fixture.litertlm", checksum)},
        ),
        patch.object(sys, "argv", ["download", str(destination)]),
        patch.object(
            urllib.request,
            "urlopen",
            return_value=io.BytesIO(content),
        ) as opening,
    ):
        fixture.main()
        assert opening.call_args.kwargs["timeout"] == 120
        fixture.main()
        assert opening.call_count == 1
    (destination / "fixture.litertlm").write_bytes(b"corrupt")
    script = """
import importlib.util
import io
from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location('fixture', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.MODELS = {'embedding': ('repo', 'revision', 'fixture.litertlm', sys.argv[3])}
sys.argv = ['download', sys.argv[2]]
with patch('urllib.request.urlopen', return_value=io.BytesIO(b'corrupt')):
    module.main()
"""
    result = subprocess.run(
        [
            sys.executable,
            "-O",
            "-c",
            script,
            str(ROOT / "tools/download_embedding_fixture.py"),
            str(destination),
            checksum,
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0
    assert "Downloaded artifact checksum mismatch" in result.stderr
    assert not (destination / "fixture.download").exists()


def test_stalled_build_command_expires_before_the_job_deadline():
    with pytest.raises(subprocess.TimeoutExpired):
        build_command(sys.executable, "-c", "import time; time.sleep(30)", timeout=0.05)


def test_timeout_gate_checks_owned_popen_waits_and_communicate():
    assert missing_timeouts(
        'from subprocess import Popen as start\nprocess = start(["git"])\nprocess.wait()'
    ) == [3]
    assert missing_timeouts(
        'import subprocess\nself.process = subprocess.Popen(["git"])\nself.process.communicate(timeout=None)'
    ) == [3]
    assert not missing_timeouts(
        'import subprocess\nprocess = subprocess.Popen(["git"])\nprocess.wait(30)\nprocess.communicate(None, 30)'
    )
    assert not missing_timeouts(
        "import threading\nevent = threading.Event()\nevent.wait()"
    )
