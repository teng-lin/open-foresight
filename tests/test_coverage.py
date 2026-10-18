"""The core coverage gate must measure exactly the filtered LCOV artifact."""

import subprocess
import sys
from pathlib import Path

import pytest

from tools.check_coverage import line_counts

SCRIPT = Path(__file__).resolve().parents[1] / "tools/check_coverage.py"


def test_duplicate_records_and_checksums_do_not_inflate_the_denominator(tmp_path):
    report = tmp_path / "coverage.info"
    report.write_text(
        "SF:lib/a.dart\nDA:1,0,checksum\nDA:2,1\nend_of_record\n"
        "SF:lib/a.dart\nDA:1,2\nDA:2,0\nend_of_record\n"
        "SF:lib/b.dart\nDA:1,0\nend_of_record\n"
    )
    assert line_counts(report) == (2, 3)


@pytest.mark.parametrize(
    "content",
    [
        "",
        "SF:file\nend_of_record\n",
        "DA:1,2\n",
        "SF:file\nDA:-1,0\n",
        "SF:file\nDA:1,-1\n",
    ],
)
def test_empty_and_invalid_reports_fail_closed(tmp_path, content):
    report = tmp_path / "coverage.info"
    report.write_text(content)
    with pytest.raises(ValueError):
        line_counts(report)


@pytest.mark.parametrize("covered,expected", [(9, 0), (8, 1)])
def test_gate_accepts_exactly_ninety_percent_and_rejects_below_it(
    tmp_path, covered, expected
):
    report = tmp_path / "coverage.info"
    report.write_text(
        "SF:lib/a.dart\n"
        + "".join(f"DA:{i + 1},{int(i < covered)}\n" for i in range(10))
    )
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(report), "--minimum", "90"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == expected
    assert f"{covered}/10" in result.stdout


@pytest.mark.parametrize("minimum", ["nan", "inf", "-1", "101"])
def test_invalid_thresholds_are_rejected(tmp_path, minimum):
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(tmp_path / "missing"), "--minimum", minimum],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 2
    assert "--minimum must be between 0 and 100" in result.stderr
