"""Source Flutter integrations receive only the verified worker's public defines."""

from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import integration_gates as gates  # noqa: E402


def test_source_context_uses_selected_sdk_current_build_and_exact_receipt(
    tmp_path, monkeypatch
):
    root = tmp_path / "source"
    build = tmp_path / "custom build"
    native = build / "native/libforesight_native.so"
    native.parent.mkdir(parents=True)
    native.write_bytes(b"fixture main library")
    dart = tmp_path / "sdk/bin/dart"
    dart.parent.mkdir(parents=True)
    dart.write_bytes(b"fixture executable path")
    dart.chmod(0o755)
    definitions = {
        "FORESIGHT_DIAGNOSTIC_NATIVE_ID": "a" * 64,
        "FORESIGHT_DIAGNOSTIC_BUILD_ID": "b" * 64,
        "FORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR": "public path with spaces",
    }
    verifier = Mock(return_value={"defines": definitions})
    monkeypatch.setitem(
        sys.modules,
        "build_diagnostic_worker",
        SimpleNamespace(verify_worker_build=verifier),
    )
    monkeypatch.setattr(gates, "ROOT", root)
    env = {"PATH": str(dart.parent), "FORESIGHT_NATIVE_LIBRARY": str(native)}
    assert gates._source_worker_defines(env, "dart") == definitions
    verifier.assert_called_once_with(
        root,
        build,
        dart.parent.parent,
        root / "packages/foresight_core/.dart_tool/package_config.json",
        "aot",
    )


def test_invalid_worker_prevents_flutter_launch_and_discards_stale_events(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(gates, "ROOT", tmp_path)

    def refused(env, dart):
        raise ValueError("worker build context mismatch")

    monkeypatch.setattr(gates, "_source_worker_defines", refused)
    launch = Mock()
    monkeypatch.setattr(gates.subprocess, "run", launch)
    events = tmp_path / "probe.events.jsonl"
    events.write_text("stale success")
    with pytest.raises(ValueError, match="worker build context mismatch"):
        gates.run_tests(
            "desktop", ["integration_test/fixture.dart"], 1, {}, tmp_path, "probe"
        )
    launch.assert_not_called()
    assert not events.exists()
    assert not (tmp_path / "apps/desktop/test/private_pipewire_fixture.dart").exists()
