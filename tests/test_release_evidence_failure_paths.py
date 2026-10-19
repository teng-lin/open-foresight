"""Acceptance reports cannot publish stale, ambiguous or unbound installers."""

import json
import sys

import pytest
from tools import release_acceptance_report as reports
from test_release_acceptance_report import receipts, evidence


@pytest.mark.parametrize(
    "failure", ["tag", "source", "functional", "kind", "mixed-sources"]
)
def test_acceptance_rejects_inconsistent_receipts(tmp_path, failure):
    receipts(tmp_path)
    path = tmp_path / "0/assets/installer.json"
    value = json.loads(path.read_text())
    if failure == "tag":
        value["tag"] = "v9.9.9"
    elif failure == "source":
        value["release_tag_commit"] = "b" * 40
    elif failure == "kind":
        value["asset"] = "unverified.zip"
    elif failure == "mixed-sources":
        value.update(source_commit="b" * 40, release_tag_commit="b" * 40)
    else:
        (tmp_path / "0/reports/functional.json").write_text('{"status":"failed"}')
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError):
        reports.aggregate(tmp_path, "v1.2.3", "")


@pytest.mark.parametrize(
    "failure", ["type", "record", "platform", "timestamp", "binding"]
)
def test_manual_evidence_requires_supported_record_and_persisted_byte_binding(
    tmp_path, failure
):
    receipts(tmp_path)
    records = evidence()
    installers = [
        {"platform": "linux", "sha256": "0" * 64},
        {"platform": "macos", "sha256": "3" * 64},
    ]
    if failure == "type":
        records = {}
    elif failure == "record":
        records[0] = "not an object"
    elif failure == "platform":
        records[0]["platform"] = "other"
        installers[0]["platform"] = "other"
    elif failure == "timestamp":
        records[0]["tested_at_utc"] = "not UTC"
    else:
        report = reports.aggregate(tmp_path, "v1.2.3", json.dumps(records))
        report["installers"][0]["sha256"] = "f" * 64
        with pytest.raises(ValueError, match="not bound"):
            reports.require_publication(report, "v1.2.3")
        return
    with pytest.raises(ValueError):
        reports.gpu_status(installers, json.dumps(records))


@pytest.mark.parametrize("mode", ["missing-args", "aggregate", "publication"])
def test_acceptance_cli_writes_only_verified_report(tmp_path, monkeypatch, mode):
    args = ["acceptance", "--tag", "v1.2.3"]
    output = tmp_path / "report.json"
    if mode != "missing-args":
        receipts(tmp_path)
        monkeypatch.setenv("GPU_EVIDENCE", json.dumps(evidence()))
        args += ["--directory", str(tmp_path), "--output", str(output)]
    if mode == "publication":
        output.write_text(
            json.dumps(reports.aggregate(tmp_path, "v1.2.3", json.dumps(evidence())))
        )
        args = ["acceptance", "--tag", "v1.2.3", "--require-publication", str(output)]
    monkeypatch.setattr(sys, "argv", args)
    if mode == "missing-args":
        with pytest.raises(SystemExit, match="2"):
            reports.main()
        assert not output.exists()
    else:
        reports.main()
        assert json.loads(output.read_text())["status"] == "passed"
