import json
import sys

import pytest

from tools import helper_protocol as protocol


def manifest(root, value):
    path = root / "proto/helper_protocol_version.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": value}))


def test_current_constants_match_one_protocol_source():
    protocol.verify_generated()
    assert protocol.HELPER_PROTOCOL_VERSION == "1.1.0"


@pytest.mark.parametrize("version", [None, 1, "1.0", "1.0.3\n"])
def test_invalid_protocol_version_is_rejected(tmp_path, version):
    manifest(tmp_path, version)
    with pytest.raises(ValueError, match="three decimal"):
        protocol.protocol_version(tmp_path)


def test_generation_checks_missing_and_drifted_files(tmp_path, monkeypatch):
    manifest(tmp_path, "1.0.3")
    expected = protocol.generated_files(tmp_path)
    with pytest.raises(ValueError, match="Stale"):
        protocol.verify_generated(tmp_path)
    for relative, content in expected.items():
        path = tmp_path / relative
        path.parent.mkdir(parents=True)
        path.write_text(content)
    protocol.verify_generated(tmp_path)
    first = tmp_path / next(iter(expected))
    first.write_text("stale")
    with pytest.raises(ValueError, match="--write"):
        protocol.verify_generated(tmp_path)
    # The real write entry point restores exactly the generated source bytes.
    monkeypatch.setattr(protocol, "ROOT", tmp_path)
    monkeypatch.setattr(protocol, "generated_files", lambda *_: expected)
    original = protocol.verify_generated
    monkeypatch.setattr(protocol, "verify_generated", lambda: original(tmp_path))
    monkeypatch.setattr(sys, "argv", ["helper_protocol.py", "--write"])
    protocol.main()
    assert first.read_text() == expected[next(iter(expected))]
