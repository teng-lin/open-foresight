"""Keep disposable Dart fixtures on the shared, disk-aware cleanup path."""

from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOTS = (
    "packages/foresight_core/test",
    "apps/desktop/test",
    "apps/desktop/integration_test",
)
RAW_TEMP = re.compile(r"Directory\s*\.\s*systemTemp\s*\.\s*createTemp(?:Sync)?\s*\(")


def check_dart_temp_directories(root):
    violations = [
        str(path.relative_to(root))
        for directory in TEST_ROOTS
        for path in (root / directory).rglob("*.dart")
        if RAW_TEMP.search(path.read_text())
    ]
    if violations:
        raise ValueError(
            "Use foresight_test_support/test_paths.dart for automatic cleanup: "
            + ", ".join(violations)
        )


def test_dart_fixtures_use_shared_temp_directory_helper():
    check_dart_temp_directories(ROOT)


@pytest.mark.parametrize("method", ["createTemp", "createTempSync"])
def test_raw_temp_guard_covers_core_widgets_and_integration(tmp_path, method):
    for directory in TEST_ROOTS:
        path = tmp_path / directory / "new_test.dart"
        path.parent.mkdir(parents=True)
        path.write_text(f"final dir = Directory.systemTemp.{method}('fixture-');")
        with pytest.raises(ValueError, match="automatic cleanup"):
            check_dart_temp_directories(tmp_path)
        path.unlink()
