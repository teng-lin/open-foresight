"""T5 indexes locate real checksummed receipts; APIs retain publication authority."""

import copy
import hashlib
import io
import json
import subprocess
from types import SimpleNamespace
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_release_candidates as candidates
from tools import ci_release_evidence as evidence

REPO, TAG, SOURCE, CONTROL, FLOOR = "owner/repo", "v1.2.3", "a" * 40, "b" * 40, "f" * 40


def zipped(member, record):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as bundle:
        bundle.writestr(member, json.dumps(record))
    return output.getvalue()


@pytest.fixture
def state(monkeypatch):
    state = SimpleNamespace(
        jobs=[], items=[], blobs={}, records={}, commands=[], assets=[], asset_bytes={}
    )
    state.attempt_starts = {1: "2026-10-19T00:00:00Z", 2: "2026-10-19T00:00:00Z"}
    state.run = {
        "id": 42,
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": CONTROL,
        "run_attempt": 2,
        "status": "completed",
        "conclusion": "failure",  # Prior publication awaited GPU evidence.
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
    }
    state.candidate = {
        "schema": 1,
        "source": SOURCE,
        "mode": "release",
        "source_floor": FLOOR,
        "candidate_runs": {"linux-app": 11, "macos-app": 11},
        "components": {
            kind: {
                "artifact_id": 100 + index,
                "artifact_digest": "sha256:" + str(index + 5) * 64,
                "payload_sha256": str(index + 3) * 64,
                "job_id": 110 + index,
                "run_attempt": 1,
                "distribution": {"version": "1.2.3", "build_number": 7},
            }
            for index, kind in enumerate(("linux-app", "macos-app"))
        },
    }

    def add(name, member, record, job_name):
        identity = 300 + len(state.items)
        raw = zipped(member, record)
        state.blobs[identity] = raw
        state.records[name] = record
        item = {
            "id": identity,
            "name": name,
            "expired": False,
            "size_in_bytes": len(raw),
            "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
            "workflow_run": {"id": 42, "head_sha": CONTROL},
            "created_at": "2026-10-19T00:00:30Z",
        }
        state.items.append(item)
        state.jobs.append(
            {
                "id": 200 + len(state.jobs),
                "name": job_name,
                "status": "completed",
                "conclusion": "success",
                "run_attempt": 1,
                "started_at": "2026-10-19T00:00:00Z",
                "completed_at": "2026-10-19T00:01:00Z",
            }
        )
        return item

    state.add = add
    installers = []
    for kind, component in evidence.KINDS.items():
        suffix = {"deb": ".deb", "rpm": ".rpm", "arch": ".pkg.tar.zst", "dmg": ".dmg"}[
            kind
        ]
        asset_id = 500 + len(state.assets)
        name = "installer" + suffix
        payload = ("original " + kind + " installer").encode()
        checksum = hashlib.sha256(payload).hexdigest()
        state.assets.extend(
            [
                {
                    "id": asset_id,
                    "name": name,
                    "size": len(payload),
                    "digest": "sha256:" + checksum,
                },
                {"name": name + ".sha256"},
                {"name": name + ".build.json"},
            ]
        )
        state.asset_bytes[asset_id] = payload
        original = state.candidate["components"][component]
        receipt = {
            "schema": 1,
            "source": SOURCE,
            "tag": TAG,
            "format": kind,
            "asset": name,
            "sha256": checksum,
            "producer_run": 42,
            "producer_attempt": 1,
            "producer_job": "dmg" if kind == "dmg" else "packages",
            "candidate": {
                "run": 11,
                "artifact_id": original["artifact_id"],
                "artifact_digest": original["artifact_digest"],
                "payload_sha256": original["payload_sha256"],
            },
        }
        add(
            "release-packaging-" + kind,
            "package-receipt.json",
            receipt,
            "macos / dmg" if kind == "dmg" else f"linux / packages ({kind})",
        )
        installers.append(
            {
                "asset": name,
                "sha256": checksum,
                "platform": "macos" if kind == "dmg" else "linux",
            }
        )
    state.report = {
        "suite_version": evidence.SUITE_VERSION,
        "source_commit": SOURCE,
        "tag": TAG,
        "status": "passed",
        "installers": installers,
        "gpu_inference": {
            "status": "manual_passed",
            "evidence": [
                {"platform": item["platform"], "installer_sha256": item["sha256"]}
                for item in (installers[0], installers[-1])
            ],
        },
    }
    add(
        "release-acceptance-summary-1",
        "release-acceptance.json",
        state.report,
        "acceptance / acceptance",
    )
    state.release = {
        "id": 9,
        "tag_name": TAG,
        "draft": True,
        "target_commitish": SOURCE,
        "assets": state.assets,
    }

    def api(repository, route):
        assert repository == REPO
        if route == f"commits/{TAG}":
            return {"sha": SOURCE}
        if route == "actions/runs/42":
            return state.run
        if route.startswith("releases?"):
            return [state.release]
        if route.startswith("actions/runs/42/attempts/"):
            attempt = int(route.rsplit("/", 1)[1])
            return {
                "id": 42,
                "head_sha": CONTROL,
                "run_attempt": attempt,
                "run_started_at": state.attempt_starts[attempt],
            }
        if route.startswith("actions/runs/42/jobs?"):
            return {"jobs": state.jobs}
        if route.startswith("actions/runs/42/artifacts?"):
            return {"artifacts": state.items}
        raise AssertionError(route)

    def command(arguments, *, stdout, check, timeout, **kwargs):
        state.commands.append(arguments)
        assert arguments[:2] == ["gh", "api"]
        route = arguments[-1]
        if route.endswith("/zip"):
            raw = state.blobs[int(route.split("/")[-2])]
        else:
            raw = state.asset_bytes[int(route.rsplit("/", 1)[-1])]
        stdout.write(raw)
        return subprocess.CompletedProcess(arguments, 0)

    monkeypatch.setattr(evidence, "api", api)
    monkeypatch.setattr(candidates, "api", api)
    monkeypatch.setattr(subprocess, "run", command)

    def candidate_evidence(repository, source, platform_runs, **kwargs):
        assert repository == REPO and source == SOURCE
        if platform_runs != state.candidate["candidate_runs"]:
            raise ValueError("Candidate locator does not match original platform runs")
        return copy.deepcopy(state.candidate)

    monkeypatch.setattr(candidates, "verified_evidence", candidate_evidence)
    state.attestations = []
    monkeypatch.setattr(
        evidence.attestations,
        "verify",
        lambda path, repo, platform, run, attempt: state.attestations.append(
            (artifacts.digest(path), platform, run["id"], attempt)
        ),
    )
    return state


def index(state):
    return evidence.record(REPO, TAG, state.candidate["candidate_runs"], 42, 42)


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", None])
def test_reused_candidates_and_original_packaging_attempts_survive_later_publication_failure(
    state, monkeypatch, ref
):
    if ref is None:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
    record = index(state)
    result = evidence.verify(
        REPO, TAG, record, current_run=99, publication_report=state.report
    )
    assert (
        result["source"] == SOURCE != state.run["head_sha"]
    )  # Tag behind main is valid.
    assert result["installers"] == state.report["installers"]
    assert all(item["attempt"] == 1 for item in record["installers"].values())
    assert {row[2:] for row in state.attestations} == {(42, 1)}
    assert all(command[:2] == ["gh", "api"] for command in state.commands)
    assert all(
        "releases/assets/" in command[-1] or "/zip" in command[-1]
        for command in state.commands
    )


@pytest.mark.parametrize(
    "role", ["linux / packages (deb)", "macos / dmg", "acceptance / acceptance"]
)
@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "success"])
def test_latest_job_attempt_is_authoritative_even_when_old_index_and_bytes_remain(
    state, role, conclusion
):
    record = index(state)
    original = next(job for job in state.jobs if job["name"] == role)
    state.jobs.append(
        {**original, "id": 999, "run_attempt": 2, "conclusion": conclusion}
    )
    with pytest.raises(ValueError):
        evidence.verify(REPO, TAG, record)


@pytest.mark.parametrize(
    "change",
    [
        "missing-index",
        "wrong-source",
        "suite",
        "floor",
        "mode",
        "missing-installer",
        "wrong-workflow",
        "wrong-repository",
        "wrong-headrepo",
        "draft-source",
        "published",
    ],
)
def test_changed_locator_or_control_identity_cannot_authorize_publication(
    state, change
):
    record = index(state)
    if change == "missing-index":
        record = {}
    elif change == "wrong-source":
        record["source"] = "c" * 40
    elif change == "suite":
        record["suite_version"] = "old"
    elif change == "floor":
        record["source_floor"] = "e" * 40
    elif change == "mode":
        record["candidate_mode"] = "legacy"
    elif change == "missing-installer":
        record["installers"].pop("rpm")
    elif change == "wrong-workflow":
        state.run["path"] = ".github/workflows/preview-packages.yml"
    elif change == "wrong-repository":
        state.run["repository"]["full_name"] = "other/repo"
    elif change == "wrong-headrepo":
        state.run["head_repository"]["full_name"] = "other/repo"
    elif change == "draft-source":
        state.release["target_commitish"] = "c" * 40
    else:
        state.release["draft"] = False
    with pytest.raises(ValueError):
        evidence.verify(REPO, TAG, record)


@pytest.mark.parametrize(
    "failure",
    [
        "expired",
        "wrong-window",
        "zip-corrupt",
        "wrong-api-digest",
        "asset-corrupt",
        "missing-attestation",
        "untested-candidate",
    ],
)
def test_actual_archive_bytes_job_window_and_candidate_checks_remain_mandatory(
    state, monkeypatch, failure
):
    record = index(state)
    item = state.items[0]
    if failure == "expired":
        item["expired"] = True
    elif failure == "wrong-window":
        item["created_at"] = "2026-10-19T01:00:00Z"
    elif failure == "zip-corrupt":
        state.blobs[item["id"]] += b"corrupt"
    elif failure == "wrong-api-digest":
        item["digest"] = "sha256:" + "0" * 64
    elif failure == "asset-corrupt":
        state.asset_bytes[500] = b"different installer"
    elif failure == "missing-attestation":
        monkeypatch.setattr(
            evidence.attestations,
            "verify",
            lambda *args: (_ for _ in ()).throw(ValueError("signature rejected")),
        )
    else:
        monkeypatch.setattr(
            candidates,
            "verified_evidence",
            lambda *args, **kwargs: (_ for _ in ()).throw(
                ValueError("preview or untested")
            ),
        )
    with pytest.raises(ValueError):
        evidence.verify(REPO, TAG, record)


@pytest.mark.parametrize(
    "field,value",
    [
        ("candidate", {}),
        ("sha256", "e" * 64),
        ("tag", "v9.9.9"),
        ("source", "c" * 40),
        ("producer_job", "unrelated"),
        ("producer_attempt", 2),
        ("producer_run", 99),
        ("schema", True),
        ("asset", "other.deb"),
        ("format", "rpm"),
    ],
)
def test_even_checksum_valid_packaging_receipt_must_bind_candidate_and_installer(
    state, field, value
):
    record = index(state)
    receipt = state.records["release-packaging-deb"]
    receipt[field] = value
    raw = zipped("package-receipt.json", receipt)
    item = state.items[0]
    state.blobs[item["id"]] = raw
    item["digest"] = "sha256:" + hashlib.sha256(raw).hexdigest()
    record["installers"]["deb"]["digest"] = item["digest"]
    with pytest.raises(ValueError, match="Packaging receipt"):
        evidence.verify(REPO, TAG, record)


@pytest.mark.parametrize("change", ["suite", "source", "status", "installers", "gpu"])
def test_publication_revalidates_installer_bound_gpu_report(state, change):
    record = index(state)
    report = copy.deepcopy(state.report)
    if change == "suite":
        report["suite_version"] = "old"
    elif change == "source":
        report["source_commit"] = "e" * 40
    elif change == "status":
        report["status"] = "automated_passed_manual_pending"
    elif change == "installers":
        report["installers"].pop()
    else:
        report["gpu_inference"]["evidence"] = []
    with pytest.raises(ValueError):
        evidence.verify(REPO, TAG, record, publication_report=report)


def add_draft_index(state, record):
    raw = json.dumps(record).encode()
    state.assets.append(
        {
            "id": 900,
            "name": evidence.INDEX,
            "size": len(raw),
            "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
        }
    )
    state.asset_bytes[900] = raw


@pytest.mark.parametrize(
    "invalid", [None, "source", "status", "installers", "job", "bytes"]
)
def test_explicit_gpu_waiver_retains_automated_and_byte_verification(
    state, tmp_path, monkeypatch, invalid
):
    record = index(state)
    add_draft_index(state, record)
    report = copy.deepcopy(state.report)
    report["status"] = "automated_passed_manual_pending"
    report["gpu_inference"] = {"status": "manual_pending", "evidence": []}
    if invalid == "source":
        report["source_commit"] = "e" * 40
    elif invalid == "status":
        report["status"] = "failed"
    elif invalid == "installers":
        report["installers"].pop()
    elif invalid == "job":
        state.jobs[0]["conclusion"] = "failure"
    elif invalid == "bytes":
        state.asset_bytes[state.assets[0]["id"]] = b"changed installer"
    path = tmp_path / "report.json"
    path.write_text(json.dumps(report))
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setattr(
        "sys.argv",
        [
            "evidence",
            "verify",
            "--tag",
            TAG,
            "--publication-report",
            str(path),
            "--skip-gpu-validation",
        ],
    )
    if invalid:
        with pytest.raises(ValueError):
            evidence.main()
    else:
        evidence.main()
        assert report["gpu_inference"]["status"] == "manual_pending"


def test_existing_index_is_reverified_and_retained_without_package_or_build_mutation(
    state,
):
    original = index(state)
    add_draft_index(state, original)
    assert evidence.record(REPO, TAG, {}, 99, 99) == original


@pytest.mark.parametrize("command", ["record", "verify"])
def test_cli_persists_read_only_index_or_publish_decision(
    state, tmp_path, monkeypatch, command
):
    record = index(state)
    add_draft_index(state, record)
    report = tmp_path / "acceptance.json"
    report.write_text(json.dumps(state.report))
    output = tmp_path / "out/result.json"
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    arguments = ["evidence", command, "--tag", TAG, "--output", str(output)]
    if command == "verify":
        arguments += ["--publication-report", str(report)]
    monkeypatch.setattr("sys.argv", arguments)
    evidence.main()
    assert json.loads(output.read_text())["source"] == SOURCE


@pytest.mark.parametrize("command", ["package", "verify"])
def test_cli_never_skips_required_local_inputs(state, monkeypatch, command):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setattr("sys.argv", ["evidence", command, "--tag", TAG])
    with pytest.raises(SystemExit, match="2"):
        evidence.main()


@pytest.mark.parametrize("kind", list(evidence.KINDS))
def test_package_cli_binds_actual_candidate_qualification_and_installer_bytes(
    tmp_path, monkeypatch, kind
):
    prefix = tmp_path / "input"
    prefix.mkdir()
    component = evidence.KINDS[kind]
    distribution = {"version": "1.2.3", "build_number": 7}
    receipt = {
        "component": component,
        "source_commit": SOURCE,
        "identity": SOURCE,
        "label": "",
        "tier": "release",
        "distribution": distribution,
        "sha256": "e" * 64,
    }
    (prefix / "source-qualification.json").write_text(
        json.dumps(
            {
                "source_receipt": receipt,
                "producer_run": 11,
                "artifact_id": 100,
                "artifact_digest": "sha256:" + "d" * 64,
            }
        )
    )
    suffix = ".manifest.json" if component == "macos-app" else ".build.json"
    (prefix / ("original" + suffix)).write_text(
        json.dumps({**distribution, "revision": SOURCE})
    )
    installer = tmp_path / ("installer." + kind)
    installer.write_bytes(b"actual installer bytes")
    metadata = {
        "sha256": artifacts.digest(installer),
        "format": kind,
        "version": "1.2.3",
        "revision": SOURCE,
        "arch": "arm64",
    }
    type(installer)(str(installer) + ".build.json").write_text(json.dumps(metadata))
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "42")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setenv("GITHUB_JOB", "dmg" if kind == "dmg" else "packages")
    output = tmp_path / "receipt.json"
    monkeypatch.setattr(
        "sys.argv",
        [
            "evidence",
            "package",
            "--tag",
            TAG,
            "--format",
            kind,
            "--installer",
            str(installer),
            "--directory",
            str(prefix),
            "--output",
            str(output),
        ],
    )
    evidence.main()
    result = json.loads(output.read_text())
    assert result["sha256"] == artifacts.digest(installer)
    assert result["candidate"]["payload_sha256"] == receipt["sha256"]
    assert result["producer_attempt"] == 1
    receipt["tier"] = "preview"
    (prefix / "source-qualification.json").write_text(
        json.dumps({"source_receipt": receipt})
    )
    with pytest.raises(ValueError, match="stable candidate"):
        evidence.package_receipt(prefix, installer, kind, TAG)
    with pytest.raises(ValueError, match="kind/tag"):
        evidence.package_receipt(prefix, installer, "unknown", TAG)
    (prefix / "source-qualification.json").unlink()
    (prefix / "source-qualification.json").symlink_to(tmp_path / "other")
    with pytest.raises(ValueError, match="regular"):
        evidence.package_receipt(prefix, installer, kind, TAG)


def test_missing_or_wrong_acceptance_workflow_is_rejected_directly(state):
    state.run["path"] = ".github/workflows/preview-packages.yml"
    with pytest.raises(ValueError, match="acceptance run"):
        evidence.acceptance_proof(REPO, 42)
    state.run["path"] = ".github/workflows/release-acceptance.yml"
    state.jobs[-1]["name"] = "acceptance"
    observed, report = evidence.acceptance_proof(REPO, 42)
    assert observed["run"] == 42 and report == state.report


def test_asset_paths_and_bytes_are_both_verified(state, tmp_path):
    with pytest.raises(ValueError, match="Unsafe"):
        evidence.download_asset(REPO, {"name": "../escape"}, tmp_path)
    asset = state.assets[0]
    asset["digest"] = "sha256:" + "e" * 64
    with pytest.raises(ValueError, match="API metadata"):
        evidence.download_asset(REPO, asset, tmp_path)


def test_locator_refresh_after_successful_acceptance_rerun_mutates_only_fixed_metadata(
    state, monkeypatch
):
    original = index(state)
    add_draft_index(state, original)
    state.add(
        "release-acceptance-summary-2",
        "release-acceptance.json",
        state.report,
        "acceptance / acceptance",
    )
    state.jobs[-1]["run_attempt"] = 2
    refreshed = index(state)
    assert refreshed["acceptance"]["attempt"] == 2
    assert refreshed["acceptance"] != original["acceptance"]
    before = copy.deepcopy(state.assets)
    run = evidence.subprocess.run
    uploads = []

    def command(args, **kwargs):
        if args[:3] == ["gh", "release", "upload"]:
            path = __import__("pathlib").Path(args[4])
            assert path.name == evidence.INDEX
            assert json.loads(path.read_text()) == refreshed
            assert args[5:] == ["--repo", REPO, "--clobber"]
            uploads.append(args)
            return subprocess.CompletedProcess(args, 0)
        return run(args, **kwargs)

    monkeypatch.setattr(evidence.subprocess, "run", command)
    assert evidence.upload_index(REPO, TAG, refreshed)
    assert len(uploads) == 1 and state.assets == before


def test_already_current_index_performs_no_metadata_or_installer_write(state):
    record = index(state)
    add_draft_index(state, record)
    assert evidence.upload_index(REPO, TAG, record) is False
    assert all(command[:2] == ["gh", "api"] for command in state.commands)


def test_stale_failed_latest_cannot_refresh_or_upload_any_asset(state):
    record = index(state)
    add_draft_index(state, record)
    state.jobs.append(
        {**state.jobs[-1], "id": 999, "run_attempt": 2, "conclusion": "failure"}
    )
    with pytest.raises(ValueError, match="Latest required job"):
        index(state)
    with pytest.raises(ValueError, match="Latest required job"):
        evidence.upload_index(REPO, TAG, record)
    assert all(command[:2] == ["gh", "api"] for command in state.commands)


@pytest.mark.parametrize("command", ["package", "verify"])
def test_metadata_upload_flag_cannot_be_used_for_other_commands(
    state, monkeypatch, command
):
    monkeypatch.setattr(
        "sys.argv", ["evidence", command, "--tag", TAG, "--upload-index"]
    )
    with pytest.raises(SystemExit, match="2"):
        evidence.main()


def test_record_upload_reuses_its_complete_verification_without_redownloading_installers(
    state, monkeypatch
):
    record = index(state)
    add_draft_index(state, record)
    state.commands.clear()
    assert evidence.record(REPO, TAG, {}, 99, 99, upload=True) == record
    downloads = [args for args in state.commands if "/releases/assets/" in args[-1]]
    assert len(downloads) == 6  # Four installers plus two reads of the small index.
    assert sum(args[-1].endswith("/900") for args in downloads) == 2


def test_record_cli_upload_scope_is_fixed_even_with_caller_output_filename(
    state, tmp_path, monkeypatch
):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "42")
    output = tmp_path / "caller-output.deb"
    monkeypatch.setattr(
        "sys.argv",
        [
            "evidence",
            "record",
            "--tag",
            TAG,
            "--output",
            str(output),
            "--upload-index",
            "--platform-runs",
            json.dumps(state.candidate["candidate_runs"]),
        ],
    )
    run = evidence.subprocess.run
    uploads = []

    def command(args, **kwargs):
        if args[:3] == ["gh", "release", "upload"]:
            assert __import__("pathlib").Path(args[4]).name == evidence.INDEX
            uploads.append(args)
            return subprocess.CompletedProcess(args, 0)
        return run(args, **kwargs)

    monkeypatch.setattr(evidence.subprocess, "run", command)
    evidence.main()
    assert len(uploads) == 1
    assert json.loads(output.read_text())["source"] == SOURCE
    assert (
        len([args for args in state.commands if "/releases/assets/" in args[-1]]) == 4
    )


def test_failed_format_retry_keeps_untouched_original_jobs_receipts_and_certificates(
    state,
):
    # Same shape as actual historical release39072570156: unrelated successful
    # Mac work reappears under a higher APIattempt but predates its start.
    state.attempt_starts[2] = "2026-10-19T00:02:00Z"
    for job in state.jobs:
        job.update(
            run_id=42,
            head_sha=CONTROL,
            steps=[{"name": "Upload proof", "conclusion": "success"}],
        )
    mac = next(job for job in state.jobs if job["name"] == "macos / dmg")
    state.jobs.append({**copy.deepcopy(mac), "id": 1203, "run_attempt": 2})
    rpm = next(job for job in state.jobs if job["name"] == "linux / packages (rpm)")
    rpm["conclusion"] = "failure"
    state.jobs.append(
        {
            **copy.deepcopy(rpm),
            "id": 1201,
            "run_attempt": 2,
            "conclusion": "success",
            "started_at": "2026-10-19T00:02:10Z",
            "completed_at": "2026-10-19T00:03:00Z",
        }
    )
    receipt = copy.deepcopy(state.records["release-packaging-rpm"])
    receipt["producer_attempt"] = 2
    raw = zipped("package-receipt.json", receipt)
    old = next(item for item in state.items if item["name"] == "release-packaging-rpm")
    state.blobs[1301] = raw
    state.items.append(
        {
            **old,
            "id": 1301,
            "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
            "size_in_bytes": len(raw),
            "created_at": "2026-10-19T00:02:30Z",
        }
    )
    record = index(state)
    assert record["installers"]["dmg"]["job"] == mac["id"]
    assert record["installers"]["dmg"]["attempt"] == 1
    assert record["installers"]["rpm"]["job"] == 1201
    assert record["installers"]["rpm"]["attempt"] == 2
    assert record["installers"]["rpm"]["artifact"] == 1301
    result = evidence.verify(REPO, TAG, record, publication_report=state.report)
    assert result["installers"] == state.report["installers"]
    assert {row[2:] for row in state.attestations} == {(42, 1), (42, 2)}
    # No package/build/upload command runs during index construction/reverification.
    assert all(command[:2] == ["gh", "api"] for command in state.commands)


def test_acceptance_failed_only_retry_keeps_all_original_installer_attempts(state):
    state.attempt_starts[2] = "2026-10-19T00:02:00Z"
    originals = list(state.jobs[:-1])
    for job in originals:
        job.update(
            run_id=42,
            head_sha=CONTROL,
            steps=[{"name": "Upload original receipt", "conclusion": "success"}],
        )
    state.jobs.extend(
        {**copy.deepcopy(job), "id": 2000 + job["id"], "run_attempt": 2}
        for job in originals
    )
    state.jobs[4]["conclusion"] = "failure"
    artifact = state.add(
        "release-acceptance-summary-2",
        "release-acceptance.json",
        state.report,
        "acceptance / acceptance",
    )
    state.jobs[-1].update(
        run_attempt=2,
        started_at="2026-10-19T00:02:10Z",
        completed_at="2026-10-19T00:03:00Z",
    )
    artifact["created_at"] = "2026-10-19T00:02:30Z"
    record = index(state)
    assert record["acceptance"]["attempt"] == 2
    assert {item["attempt"] for item in record["installers"].values()} == {1}
    assert {row[2:] for row in state.attestations} == {(42, 1)}
    assert all(command[:2] == ["gh", "api"] for command in state.commands)


def test_missing_publication_index_retains_bytes_and_names_original_run_recovery(
    state, monkeypatch, tmp_path
):
    report = tmp_path / "publication.json"
    report.write_text(json.dumps(state.report))
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setattr(
        "sys.argv",
        ["evidence", "verify", "--tag", TAG, "--publication-report", str(report)],
    )
    before = copy.deepcopy(state.assets)
    with pytest.raises(ValueError, match="original release.yml"):
        evidence.main()
    assert state.assets == before and state.commands == []


def test_fresh_partial_coordinator_cannot_replace_missing_original_packaging_proof(
    state,
):
    state.jobs[:] = [job for job in state.jobs if job["name"] != "macos / dmg"]
    with pytest.raises(ValueError, match="gh run rerun ORIGINAL_RUN --failed"):
        index(state)
    assert all(command[:2] == ["gh", "api"] for command in state.commands)


def test_actual_dmg_receipt_shell_requires_only_python3_and_binds_real_bytes(tmp_path):
    import os
    import sys
    import yaml
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    (tmp_path / "tools").symlink_to(root / "tools", target_is_directory=True)
    prefix = tmp_path / "artifacts"
    prefix.mkdir()
    distribution = {"version": "1.2.3", "build_number": 7}
    (prefix / "source-qualification.json").write_text(
        json.dumps(
            {
                "source_receipt": {
                    "component": "macos-app",
                    "source_commit": SOURCE,
                    "identity": SOURCE,
                    "tier": "release",
                    "label": "",
                    "distribution": distribution,
                    "sha256": "e" * 64,
                },
                "producer_run": 11,
                "artifact_id": 100,
                "artifact_digest": "sha256:" + "d" * 64,
            }
        )
    )
    (prefix / "original.manifest.json").write_text(
        json.dumps({**distribution, "revision": SOURCE})
    )
    dist = tmp_path / "dist"
    dist.mkdir()
    installer = dist / "installer.dmg"
    installer.write_bytes(b"actual fixture installer bytes")
    Path(str(installer) + ".build.json").write_text(
        json.dumps(
            {
                "sha256": artifacts.digest(installer),
                "format": "dmg",
                "version": "1.2.3",
                "revision": SOURCE,
                "arch": "arm64",
            }
        )
    )
    binary = tmp_path / "bin"
    binary.mkdir()
    (binary / "python3").symlink_to(sys.executable)
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in ("BASH_ENV", "ENV")
    }
    env.update(
        PATH=str(binary),
        GITHUB_REPOSITORY=REPO,
        GITHUB_RUN_ID="42",
        GITHUB_RUN_ATTEMPT="2",
        GITHUB_JOB="dmg",
        RELEASE_TAG=TAG,
    )
    workflow = yaml.safe_load(
        (root / ".github/workflows/macos-release.yml").read_text()
    )
    step = next(
        s
        for s in workflow["jobs"]["dmg"]["steps"]
        if s.get("name") == "Bind the DMG to its original verified candidate"
    )
    result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-e",
            "-o",
            "pipefail",
            "-c",
            step["run"],
        ],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    receipt = json.loads((tmp_path / "test-results/package-receipt.json").read_text())
    assert receipt["sha256"] == artifacts.digest(installer)
    assert (
        receipt["producer_run"] == 42
        and receipt["producer_attempt"] == 2
        and receipt["producer_job"] == "dmg"
    )
    assert receipt["candidate"] == {
        "run": 11,
        "artifact_id": 100,
        "artifact_digest": "sha256:" + "d" * 64,
        "payload_sha256": "e" * 64,
    }
