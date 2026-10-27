"""The fast source gate binds only SQL support beside its selected native file."""

from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import integration_gates as gates  # noqa: E402


@pytest.mark.parametrize("invalid", ["missing", "directory", "symlink"])
def test_fast_refuses_missing_or_indirect_sql_even_when_host_supplies_one(
    tmp_path, monkeypatch, invalid
):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    native = tmp_path / "libforesight_native.so"
    native.touch()
    sql = tmp_path / "libforesight_sql_support.so"
    if invalid == "directory":
        sql.mkdir()
    elif invalid == "symlink":
        target = tmp_path / "foreign.so"
        target.touch()
        sql.symlink_to(target)
    launch = Mock()
    monkeypatch.setattr(gates, "run_tests", launch)
    args = SimpleNamespace(
        native=native, output=tmp_path, flutter="flutter", dart="dart"
    )
    with pytest.raises(ValueError, match="requires its SQL support library"):
        gates.fast_gate(
            args,
            {"PATH": "/bin", "FORESIGHT_TEST_SQL_SUPPORT_LIBRARY": "/host/foreign.so"},
        )
    launch.assert_not_called()


def test_fast_binds_the_selected_source_sql_without_inheriting_host_override(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    native = tmp_path / "libforesight_native.so"
    sql = tmp_path / "libforesight_sql_support.so"
    native.touch()
    sql.touch()
    env = {"PATH": "/bin", "FORESIGHT_TEST_SQL_SUPPORT_LIBRARY": "/host/foreign.so"}
    launch = Mock(return_value={"passed": 2})
    monkeypatch.setattr(gates, "run_tests", launch)
    args = SimpleNamespace(
        native=native, output=tmp_path, flutter="flutter", dart="dart"
    )
    assert gates.fast_gate(args, env) == {"passed": 2}
    package, files, expected, selected, *_ = launch.call_args.args
    assert package == "desktop"
    assert files == ["test/answer_failure_test.dart", "test/capture_failure_test.dart"]
    assert expected == 2
    assert selected["FORESIGHT_TEST_SQL_SUPPORT_LIBRARY"] == str(sql.resolve())
    assert env["FORESIGHT_TEST_SQL_SUPPORT_LIBRARY"] == "/host/foreign.so"
