"""Wire-level controls ensure negative first-run fixtures cannot accidentally pass."""

import hashlib
import http.client
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent / "service"))
from first_run_loopback import LoopbackModels  # noqa: E402


def control(connection, mode):
    connection.request(
        "POST",
        "/control",
        json.dumps({"mode": mode}),
        {"Content-Type": "application/json"},
    )
    response = connection.getresponse()
    assert response.status == 200
    assert json.loads(response.read())["mode"] == mode


def test_interruption_never_completes_even_a_one_byte_resumed_range():
    with LoopbackModels() as fixture:
        connection = http.client.HTTPConnection(
            "127.0.0.1", fixture.server.server_port, timeout=5
        )
        try:
            control(connection, "interrupt")
            last = len(fixture.payloads["generation"]) - 1
            connection.request(
                "GET", "/generation", headers={"Range": f"bytes={last}-{last}"}
            )
            response = connection.getresponse()
            assert (
                response.status == 206 and response.getheader("Content-Length") == "1"
            )
            with pytest.raises(http.client.IncompleteRead) as interrupted:
                response.read()
            assert interrupted.value.partial == b"" and interrupted.value.expected == 1
        finally:
            connection.close()


def test_corrupt_response_preserves_length_but_rejects_the_metadata_digest():
    with LoopbackModels() as fixture:
        connection = http.client.HTTPConnection(
            "127.0.0.1", fixture.server.server_port, timeout=5
        )
        try:
            for mode, matches in [("corrupt", False), ("good", True)]:
                control(connection, mode)
                connection.request("GET", "/generation")
                response = connection.getresponse()
                payload = response.read()
                pin = fixture.catalog["generation"][0]
                assert response.status == 200 and len(payload) == pin["bytes"]
                assert (hashlib.sha256(payload).hexdigest() == pin["sha256"]) is matches
        finally:
            connection.close()
