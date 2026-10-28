import importlib.util
import os
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location(
    "packaged_model_probe", ROOT / "tools/test_packaged_model_runtime.py"
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class PackagedModelProtocolTest(unittest.TestCase):
    def peer(self, script, root):
        return probe.Peer(
            [sys.executable, "-u", "-c", script],
            dict(os.environ),
            root,
            root / "worker.stderr",
            5,
        )

    def test_graceful_exit_without_extra_stdout_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            peer = self.peer(
                'import sys; print("ready"); sys.stdin.read()', Path(temporary)
            )
            self.assertEqual(peer.receive(), "ready")
            peer.close()
            self.assertEqual(peer.process.returncode, 0)

    def test_native_teardown_noise_after_last_response_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            peer = self.peer(
                'import sys; print("ready"); sys.stdin.read(); print("native teardown noise")',
                Path(temporary),
            )
            self.assertEqual(peer.receive(), "ready")
            with self.assertRaisesRegex(
                RuntimeError, "Unexpected trailing worker stdout"
            ):
                peer.close()
            self.assertEqual(peer.process.returncode, 0)


if __name__ == "__main__":
    unittest.main()


@pytest.mark.parametrize("failure", ["timeout", "exit", "json", "utf8"])
def test_capability_failure_retains_actual_child_output(tmp_path, failure):
    runner = tmp_path / "runner"
    captured = b"invalid json" if failure == "json" else b"partial capability\xff"
    runner.write_text(
        f"#!{sys.executable}\n"
        "import os, time\n"
        f"os.write(1, {captured!r})\n"
        "os.write(2, b'capability stderr\\xfe')\n"
        + ("time.sleep(10)\n" if failure == "timeout" else "")
        + ("raise SystemExit(7)\n" if failure == "exit" else "")
    )
    runner.chmod(0o700)
    expected = {
        "timeout": subprocess.TimeoutExpired,
        "exit": RuntimeError,
        "json": json.JSONDecodeError,
        "utf8": UnicodeDecodeError,
    }[failure]
    with pytest.raises(expected):
        probe.generation_probe(
            runner,
            tmp_path / "model",
            "cpu",
            dict(os.environ),
            tmp_path,
            tmp_path,
            1 if failure == "timeout" else 2,
        )
    assert (tmp_path / "cpu-capabilities.stdout").read_bytes() == captured
    assert (
        tmp_path / "cpu-capabilities.stderr"
    ).read_bytes() == b"capability stderr\xfe"


@pytest.mark.parametrize("failure", ["timeout", "exit", "utf8"])
def test_peer_failure_retains_actual_raw_frames_and_retires_reader(tmp_path, failure):
    script = "import os, sys; os.write(1, b'ready\\npartial frame\\n'); " + (
        "os.write(1, b'invalid\\xff'); raise SystemExit(0)"
        if failure == "utf8"
        else "raise SystemExit(7)"
        if failure == "exit"
        else "sys.stdin.read()"
    )
    peer = probe.Peer(
        [sys.executable, "-u", "-c", script],
        dict(os.environ),
        tmp_path,
        tmp_path / "worker.stderr",
        2,
    )
    try:
        assert peer.receive() == "ready"
        assert peer.receive() == "partial frame"
        with pytest.raises(
            {"timeout": TimeoutError, "exit": EOFError, "utf8": UnicodeDecodeError}[
                failure
            ]
        ):
            peer.receive()
    finally:
        if failure == "exit":
            with pytest.raises(RuntimeError, match="Worker exited 7"):
                peer.close()
        else:
            peer.close()
    assert not peer.reader.is_alive() and peer.log.closed
    assert (tmp_path / "worker.stdout").read_bytes() == (
        b"ready\npartial frame\n" + (b"invalid\xff" if failure == "utf8" else b"")
    )


@pytest.mark.parametrize("newline", ["\n", "\r\n"])
def test_successful_persistent_generation_retains_both_requests(tmp_path, newline):
    runner = tmp_path / "runner"
    runner.write_text(
        f"#!{sys.executable}\n"
        "import json, sys\n"
        f"def emit(value): print(value, end={newline!r}, flush=True)\n"
        "if '--probe' in sys.argv:\n"
        " print(json.dumps({'native_stop_token_sequences': True}))\n"
        "else:\n"
        " emit('ready 1')\n"
        " for line in sys.stdin:\n"
        "  if line.strip() == 'shutdown': break\n"
        "  _, token, _ = line.split(' ', 2)\n"
        "  emit(token + ' answer ' + json.dumps({'content': '4'}))\n"
        "  emit(token + ' done completed')\n"
    )
    runner.chmod(0o700)
    result = probe.generation_probe(
        runner, tmp_path / "model", "cpu", dict(os.environ), tmp_path, tmp_path, 2
    )
    assert result["same_engine_process_two_requests"] is True
    assert len(result["requests"]) == 2
    assert json.loads((tmp_path / "cpu-capabilities.stdout").read_text()) == {
        "native_stop_token_sequences": True
    }
    assert (tmp_path / "cpu-generation.stdout").read_text().splitlines() == [
        "ready 1",
        '1 answer {"content": "4"}',
        "1 done completed",
        '2 answer {"content": "4"}',
        "2 done completed",
    ]
    assert (tmp_path / "cpu-generation.stdout").read_bytes().count(
        newline.encode()
    ) == 5
    assert json.loads((tmp_path / "cpu-generation-shutdown.json").read_text()) == {
        "graceful_shutdown": True,
        "exit_code": 0,
    }


def test_successful_embedding_retains_identity_and_both_responses(tmp_path):
    worker = tmp_path / "worker"
    worker.write_text(
        f"#!{sys.executable}\n"
        "import json, sys\n"
        f"print(json.dumps({{'digest': {probe.EMBEDDING_SHA256!r}, 'dimensions': 768, "
        "'backend': 'litert-lm-embedding-cpu'}), flush=True)\n"
        "for line in sys.stdin:\n"
        " request = json.loads(line)\n"
        " print(json.dumps({'result': [1.0] + [0.0] * 767}), flush=True)\n"
    )
    worker.chmod(0o700)
    result = probe.embedding_probe(
        worker, tmp_path / "model", "cpu", dict(os.environ), tmp_path, tmp_path, 2
    )
    assert result["document_and_query_finite_normalized_768"] is True
    frames = (tmp_path / "cpu-embedding.stdout").read_text().splitlines()
    assert len(frames) == 3
    assert json.loads(frames[0]) == result["identity"]
    assert all(
        json.loads(frame)["result"] == [1.0] + [0.0] * 767 for frame in frames[1:]
    )
    assert json.loads((tmp_path / "cpu-embedding-shutdown.json").read_text()) == {
        "graceful_shutdown": True,
        "exit_code": 0,
    }
