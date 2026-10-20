"""Real receipt ZIP/checksum proofs and authoritative candidate job attempts."""

import base64
import hashlib
import io
import json
import subprocess
import sys
import tarfile
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_release_candidates as candidates
from tools import prepare_release

REPOSITORY = "owner/repo"
SOURCE = "1" * 40
FLOOR = "0" * 40
CONTROL = "3" * 40


def zipped(member, record):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as bundle:
        bundle.writestr(member, json.dumps(record))
    return buffer.getvalue()


@pytest.fixture
def producer(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GITHUB_SHA", CONTROL)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("RELEASE_SOURCE_FLOOR", FLOOR)
    state = SimpleNamespace(
        items=[], blobs={}, downloads=[], requests=[], next_id=1000, floor=FLOOR
    )
    state.run = {
        "id": 42,
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_repository": {"full_name": REPOSITORY},
        "head_sha": CONTROL,
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
    }
    state.jobs = [
        {
            "id": index + 10,
            "name": "candidates / " + name,
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
            "started_at": "2026-10-19T00:00:00Z",
            "completed_at": "2026-10-19T00:01:00Z",
        }
        for index, name in enumerate(candidates.GATES)
    ]
    state.jobs.append({**state.jobs[0], "id": 900, "name": "candidate-receipt"})

    def add(name, blob):
        state.next_id += 1
        item = {
            "id": state.next_id,
            "name": name,
            "workflow_run": {"id": 42},
            "expired": False,
            "digest": "sha256:" + hashlib.sha256(blob).hexdigest(),
            "created_at": "2026-10-19T00:00:30Z",
            "size_in_bytes": len(blob),
        }
        state.items.append(item)
        state.blobs[item["id"]] = blob
        return item

    state.add = add

    def find(name):
        return next(item for item in state.items if item["name"] == name)

    state.item = find

    def change(name, update):
        item = find(name)
        with zipfile.ZipFile(io.BytesIO(state.blobs[item["id"]])) as bundle:
            member = bundle.namelist()[0]
            record = json.loads(bundle.read(member))
        update(record)
        state.blobs[item["id"]] = zipped(member, record)
        item["digest"] = "sha256:" + hashlib.sha256(state.blobs[item["id"]]).hexdigest()
        item["size_in_bytes"] = len(state.blobs[item["id"]])

    state.change = change

    monkeypatch.setattr(artifacts.subprocess, "check_output", lambda *a, **kw: SOURCE)
    state.receipts = {}
    for component in candidates.COMPONENTS:
        prefix = tmp_path / component
        prefix.mkdir()
        (prefix / "application").write_bytes(b"compiled fixture, never rebuilt")
        metadata = (
            "application.build.json"
            if component == "linux-app"
            else "application.manifest.json"
        )
        (prefix / metadata).write_text(
            json.dumps({"revision": SOURCE, "version": "1.2.3", "build_number": 7})
        )
        output = tmp_path / (component + "-upload")
        with monkeypatch.context() as packing:
            packing.setenv("GITHUB_RUN_ATTEMPT", "1")
            artifacts.pack(component, SOURCE, prefix, output, tier="release", label="")
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            for member in ("identity.json", "payload.tar.gz"):
                bundle.write(output / member, member)
        payload = add(artifacts.name(component, SOURCE), buffer.getvalue())
        receipt = json.loads((output / "identity.json").read_text())
        state.receipts[component] = receipt
        add(
            artifacts.receipt_name(component, SOURCE),
            zipped(
                "receipt.json",
                {
                    "schema": 1,
                    "component": component,
                    "identity": SOURCE,
                    "artifact_id": payload["id"],
                    "artifact_digest": payload["digest"],
                    "source_receipt": receipt,
                },
            ),
        )
    linux = find(artifacts.name("linux-app", SOURCE))
    for name in candidates.CONSUMERS:
        add(
            f"ci-release-input-{name}-{SOURCE}",
            zipped(
                "consumption.json",
                {
                    "schema": 1,
                    "source": SOURCE,
                    "component": "linux-app",
                    "artifact_id": linux["id"],
                    "artifact_digest": linux["digest"],
                    "payload_sha256": state.receipts["linux-app"]["sha256"],
                    "source_run_attempt": 1,
                    "consumer_run_id": 42,
                    "consumer_run_attempt": 1,
                },
            ),
        )

    def api(repository, route):
        assert repository == REPOSITORY
        state.requests.append(route)
        if route == "commits/main":
            return {"sha": CONTROL}
        if route.startswith("compare/"):
            older, newer = route.removeprefix("compare/").split("...")
            ranks = {FLOOR: 0, SOURCE: 1, "2" * 40: 2, CONTROL: 3}
            return {
                "status": "identical"
                if older == newer
                else "ahead"
                if older in ranks and newer in ranks and ranks[older] < ranks[newer]
                else "diverged"
            }
        if route.startswith("contents/"):
            return {
                "encoding": "base64",
                "content": base64.b64encode(b"version: 1.2.3+4\n").decode(),
            }
        if route.startswith("git/matching-refs/tags/"):
            return [{"ref": "refs/tags/v1.2.3"}]
        if route == "commits/v1.2.3":
            return {"sha": SOURCE}
        if route == "actions/runs/42":
            return state.run
        if route.startswith("actions/runs/42/attempts/"):
            return {
                "id": 42,
                "head_sha": CONTROL,
                "run_attempt": int(route.rsplit("/", 1)[1]),
                "run_started_at": "2026-10-19T00:00:00Z",
            }
        if route.startswith("actions/runs/42/jobs?"):
            query = parse_qs(urlsplit(route).query)
            size = int(query["per_page"][0])
            page = int(query["page"][0])
            return {"jobs": state.jobs[(page - 1) * size : page * size]}
        if route.startswith("actions/runs/42/artifacts?"):
            return {"artifacts": state.items}
        if route.startswith("actions/artifacts?"):
            name = route.split("name=", 1)[1].split("&", 1)[0]
            return {"artifacts": [item for item in state.items if item["name"] == name]}
        if route.startswith("actions/artifacts/"):
            return next(
                item
                for item in state.items
                if item["id"] == int(route.rsplit("/", 1)[1])
            )
        raise AssertionError(route)

    state.api = api
    for module in (candidates, artifacts, prepare_release):
        monkeypatch.setattr(module, "api", api)

    def download(command, *, stdout, **kwargs):
        assert command[:2] == ["gh", "api"]
        assert command[-1].endswith(
            "/zip"
        )  # No dispatch, stamp, build or API mutation.
        artifact_id = int(command[-1].split("/")[-2])
        state.downloads.append(artifact_id)
        stdout.write(state.blobs[artifact_id])
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(artifacts.subprocess, "run", download)

    def index():
        state.items[:] = [
            item
            for item in state.items
            if item["name"] != f"ci-release-candidate-{SOURCE}"
        ]
        record = candidates.collect(
            REPOSITORY, SOURCE, state.run, floor=state.floor, receipt_attempt=1
        )
        add(f"ci-release-candidate-{SOURCE}", zipped("release-candidate.json", record))
        return record

    state.index = index
    state.record = index()
    state.outputs = {"source": SOURCE, "version": "1.2.3", "build_number": "7"}
    for component, platform in (("linux-app", "linux"), ("macos-app", "macos")):
        part = state.record["components"][component]
        state.outputs.update(
            {
                f"{platform}_bundle_id": str(part["artifact_id"]),
                f"{platform}_bundle_digest": part["artifact_digest"].removeprefix(
                    "sha256:"
                ),
                f"{platform}_bundle_attempt": str(part["run_attempt"]),
            }
        )
    return state


def test_verified_index_reuses_original_payload_without_downloading_or_relabeling_it(
    producer,
):
    assert candidates.verify(REPOSITORY, SOURCE, 42) == producer.record
    assert candidates.find(REPOSITORY, SOURCE)["run_id"] == 42
    assert producer.record["tested"] is True
    assert set(producer.record["gates"]) == set(candidates.GATES)
    payload_ids = {
        part["artifact_id"] for part in producer.record["components"].values()
    }
    assert payload_ids.isdisjoint(producer.downloads)
    evidence = candidates.verified_evidence(
        REPOSITORY, SOURCE, {name: 42 for name in candidates.COMPONENTS}
    )
    assert evidence["mode"] == "release"
    assert evidence["components"] == producer.record["components"]


@pytest.mark.parametrize("requested_run", [None, 42])
def test_prepare_adapter_requalifies_original_candidates_for_each_source_mode(
    producer, requested_run
):
    assert prepare_release.candidate_runs(REPOSITORY, SOURCE, requested_run) == {
        component: 42 for component in candidates.COMPONENTS
    }
    assert producer.downloads


@pytest.mark.parametrize(
    "field,value",
    [
        ("schema", True),
        ("component", "macos-app"),
        ("artifact_id", 17),
        ("artifact_digest", "sha256:" + "f" * 64),
    ],
)
def test_sidecar_cannot_substitute_another_original_payload(producer, field, value):
    producer.change(
        artifacts.receipt_name("linux-app", SOURCE),
        lambda record: record.update({field: value}),
    )
    with pytest.raises(ValueError, match="does not bind its original payload"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize("name", candidates.GATES)
@pytest.mark.parametrize("state", ["failure", "skipped", "cancelled"])
def test_claimed_tested_index_cannot_promote_any_failed_or_skipped_required_job(
    producer, name, state
):
    next(job for job in producer.jobs if job["name"] == "candidates / " + name)[
        "conclusion"
    ] = state
    with pytest.raises(ValueError, match="Latest required job"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize(
    "field,value",
    [
        ("tier", "preview"),
        ("tier", "sweep"),
        ("tier", None),
        ("label", "nightly"),
        ("source_commit", "e" * 40),
        ("source_run_attempt", 2),
        ("source_run_attempt", True),
    ],
)
def test_preview_or_changed_original_receipt_is_refused(producer, field, value):
    producer.change(
        artifacts.receipt_name("linux-app", SOURCE),
        lambda item: item["source_receipt"].update({field: value}),
    )
    with pytest.raises(ValueError, match="mismatched"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize(
    "field,value",
    [
        ("tested", False),
        ("tested", 1),
        ("schema", True),
        ("source", "e" * 40),
        ("source_floor", "f" * 40),
        ("tier", "preview"),
        ("label", "nightly"),
        ("run_attempt", 2),
    ],
)
def test_index_is_only_a_locator_and_cannot_replace_current_api_proofs(
    producer, field, value
):
    producer.change(
        f"ci-release-candidate-{SOURCE}", lambda item: item.update({field: value})
    )
    with pytest.raises(ValueError, match="Candidate index differs"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize("gate", candidates.CONSUMERS)
@pytest.mark.parametrize(
    "field,value",
    [
        ("artifact_id", 17),
        ("artifact_digest", "sha256:" + "a" * 64),
        ("payload_sha256", "b" * 64),
        ("consumer_run_attempt", 2),
        ("consumer_run_id", 17),
        ("source_run_attempt", True),
    ],
)
def test_consumer_proof_must_describe_exact_stamped_linux_bytes(
    producer, gate, field, value
):
    producer.change(
        f"ci-release-input-{gate}-{SOURCE}", lambda item: item.update({field: value})
    )
    with pytest.raises(ValueError, match="did not consume"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize(
    "field,value",
    [
        ("path", ".github/workflows/preview-packages.yml"),
        ("event", "push"),
        ("head_branch", "feature"),
        ("head_repository", {"full_name": "fork/repo"}),
        ("status", "in_progress"),
        ("run_attempt", True),
    ],
)
def test_only_current_successful_main_release_controller_is_trusted(
    producer, field, value
):
    producer.run[field] = value
    with pytest.raises(ValueError, match="completed reviewed-main"):
        candidates.verify(REPOSITORY, SOURCE, 42)


def test_current_release_can_prepare_after_candidate_receipt_without_waiting_for_its_own_packaging(
    producer,
):
    producer.run.update(status="in_progress", conclusion=None)
    assert candidates.verify(REPOSITORY, SOURCE, 42, current_run=42)["tested"] is True
    producer.jobs[-1]["conclusion"] = "in_progress"
    with pytest.raises(ValueError, match="Latest required job"):
        candidates.verify(REPOSITORY, SOURCE, 42, current_run=42)


@pytest.mark.parametrize(
    "name",
    [
        f"ci-release-candidate-{SOURCE}",
        artifacts.name("linux-app", SOURCE),
        artifacts.receipt_name("macos-app", SOURCE),
        f"ci-release-input-linux-test-{SOURCE}",
    ],
)
def test_missing_expired_duplicate_or_late_original_upload_cannot_promote(
    producer, name
):
    item = producer.item(name)
    item["created_at"] = "2026-10-20T00:00:00Z"
    with pytest.raises(ValueError, match="original upload"):
        candidates.verify(REPOSITORY, SOURCE, 42)


def test_component_outputs_must_match_original_artifact_digest_and_attempt(producer):
    assert (
        candidates.collect(
            REPOSITORY,
            SOURCE,
            producer.run,
            floor=FLOOR,
            receipt_attempt=1,
            outputs=producer.outputs,
        )
        == producer.record
    )
    producer.outputs["linux_bundle_digest"] = "f" * 64
    with pytest.raises(ValueError, match="outputs differ"):
        candidates.collect(
            REPOSITORY,
            SOURCE,
            producer.run,
            floor=FLOOR,
            receipt_attempt=1,
            outputs=producer.outputs,
        )


def test_candidates_only_reuses_before_any_identity_allocation_or_build(producer):
    result = candidates.preflight(
        REPOSITORY, CONTROL, ref="refs/heads/main", source=SOURCE, candidates_only=True
    )
    assert result["reuse"] == "true" and result["candidate_run"] == "42"
    assert result["source"] == SOURCE
    assert (
        candidates.preflight(
            REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3", publish_only=True
        )["reuse"]
        == "true"
    )


def test_per_merge_bundles_do_not_prevent_new_release_candidates(producer):
    producer.items[:] = [
        item
        for item in producer.items
        if not item["name"].startswith(
            ("ci-release-candidate-", "ci-linux-app-", "ci-macos-app-", "receipt-ci-")
        )
    ]
    producer.add("main-linux-app-" + SOURCE, b"existing per-merge bytes")
    result = candidates.preflight(
        REPOSITORY, CONTROL, ref="refs/heads/main", source=SOURCE, candidates_only=True
    )
    assert result["reuse"] == "false"
    assert result["mode"] == "release"
    with pytest.raises(ValueError, match="publish_only"):
        candidates.preflight(
            REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3", publish_only=True
        )


@pytest.mark.parametrize("index_state", ["missing", "expired"])
def test_missing_or_expired_index_allows_a_fresh_fully_gated_build(
    producer, index_state
):
    producer.downloads.clear()
    index = producer.item(f"ci-release-candidate-{SOURCE}")
    if index_state == "missing":
        producer.items.remove(index)
    else:
        index["expired"] = True
    # Even surviving payloads cannot qualify for reuse without their tested index.
    result = candidates.preflight(
        REPOSITORY, CONTROL, ref="refs/heads/main", source=SOURCE, candidates_only=True
    )
    assert result["reuse"] == "false"
    assert result["mode"] == "release"
    assert not producer.downloads
    assert (
        prepare_release.candidate_runs(REPOSITORY, SOURCE, consumer="release-candidate")
        == {}
    )


@pytest.mark.parametrize("state", ["missing", "expired"])
@pytest.mark.parametrize(
    "name",
    [
        artifacts.name("linux-app", SOURCE),
        artifacts.receipt_name("macos-app", SOURCE),
        f"ci-release-input-linux-test-{SOURCE}",
    ],
)
def test_live_index_with_unavailable_originals_allows_new_build_but_never_reuse(
    producer, state, name
):
    item = producer.item(name)
    if state == "missing":
        producer.items.remove(item)
    else:
        item["expired"] = True
    assert candidates.find(REPOSITORY, SOURCE) is None
    result = candidates.preflight(
        REPOSITORY, CONTROL, ref="refs/heads/main", source=SOURCE, candidates_only=True
    )
    assert result["reuse"] == "false"
    with pytest.raises(
        ValueError, match="Requested fully tested release candidate is unavailable"
    ):
        candidates.find(REPOSITORY, SOURCE, 42)
    with pytest.raises(ValueError, match="publish_only"):
        candidates.preflight(
            REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3", publish_only=True
        )


@pytest.mark.parametrize("failure", ["duplicate", "late", "wrong-run", "checksum"])
def test_live_index_with_invalid_originals_remains_fatal(producer, failure):
    item = producer.item(artifacts.name("linux-app", SOURCE))
    if failure == "duplicate":
        producer.items.append(dict(item))
    elif failure == "late":
        item["created_at"] = "2026-10-20T00:00:00Z"
    elif failure == "wrong-run":
        item["workflow_run"] = {"id": 43}
    else:
        item["digest"] = "invalid"
    with pytest.raises(
        ValueError, match="Existing tested candidate evidence failed verification"
    ):
        candidates.find(REPOSITORY, SOURCE)


@pytest.mark.parametrize(
    "failure", ["duplicate", "late", "wrong-run", "digest", "index-tier", "index-gates"]
)
def test_expired_first_payload_cannot_hide_invalid_later_originals(producer, failure):
    producer.item(artifacts.name("linux-app", SOURCE))["expired"] = True
    item = producer.item(artifacts.receipt_name("macos-app", SOURCE))
    if failure == "duplicate":
        producer.items.append(dict(item))
    elif failure == "late":
        item["created_at"] = "2026-10-20T00:00:00Z"
    elif failure == "wrong-run":
        producer.item(f"ci-release-input-linux-test-{SOURCE}")["workflow_run"] = {
            "id": 43
        }
    elif failure == "digest":
        item["digest"] = "invalid"
    elif failure == "index-tier":
        producer.change(
            f"ci-release-candidate-{SOURCE}",
            lambda record: record.update(tier="preview"),
        )
    else:
        producer.change(
            f"ci-release-candidate-{SOURCE}",
            lambda record: record["gates"]["linux-test"].update(job_id=999),
        )
    with pytest.raises(
        ValueError, match="Existing tested candidate evidence failed verification"
    ):
        candidates.find(REPOSITORY, SOURCE)


def test_expiry_build_decision_logs_the_original_run_and_missing_artifact(
    producer, capsys
):
    name = artifacts.name("linux-app", SOURCE)
    producer.item(name)["expired"] = True
    assert candidates.find(REPOSITORY, SOURCE) is None
    message = capsys.readouterr().err
    assert "Original candidate run 42 not reusable" in message
    assert name in message
    assert "fresh fully gated build is permitted" in message


def test_missing_index_never_turns_a_source_api_decode_failure_into_a_build(
    producer, monkeypatch
):
    producer.items.remove(producer.item(f"ci-release-candidate-{SOURCE}"))
    previous = producer.api

    def request(repository, route):
        if route.startswith("compare/"):
            raise json.JSONDecodeError("truncated API response", "", 0)
        return previous(repository, route)

    monkeypatch.setattr(candidates, "api", request)
    with pytest.raises(json.JSONDecodeError):
        candidates.preflight(
            REPOSITORY,
            CONTROL,
            ref="refs/heads/main",
            source=SOURCE,
            candidates_only=True,
        )


@pytest.mark.parametrize("floor", ["", "main", "f" * 40, None])
def test_floor_is_explicit_and_reachable_from_reviewed_main(
    producer, monkeypatch, floor
):
    if floor is None:
        monkeypatch.delenv("RELEASE_SOURCE_FLOOR")
    else:
        monkeypatch.setenv("RELEASE_SOURCE_FLOOR", floor)
    with pytest.raises(ValueError):
        candidates.source_policy(REPOSITORY, SOURCE, CONTROL)


def test_digest_and_small_archive_checks_are_real(producer):
    item = producer.item(f"ci-release-candidate-{SOURCE}")
    producer.blobs[item["id"]] += b"changed transport bytes"
    with pytest.raises(ValueError, match="ZIP digest mismatch"):
        candidates.verify(REPOSITORY, SOURCE, 42)


def test_manual_gpu_pending_failure_does_not_force_rebuilding_tested_candidates(
    producer,
):
    producer.run["conclusion"] = "failure"
    producer.jobs.append(
        {**producer.jobs[0], "id": 950, "name": "publish", "conclusion": "failure"}
    )
    result = candidates.preflight(
        REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3", publish_only=True
    )
    assert result["reuse"] == "true"
    assert result["candidate_run"] == "42"
    producer.jobs[0]["conclusion"] = "failure"
    with pytest.raises(ValueError, match="Requested fully tested"):
        candidates.preflight(
            REPOSITORY,
            CONTROL,
            ref="refs/heads/main",
            tag="v1.2.3",
            candidate_run=42,
            publish_only=True,
        )


def test_api_json_failures_never_authorize_candidate_rebuilding(producer, monkeypatch):
    def broken(*args, **kwargs):
        raise json.JSONDecodeError("truncated API response", "", 0)

    monkeypatch.setattr(candidates, "verify", broken)
    with pytest.raises(json.JSONDecodeError):
        candidates.find(REPOSITORY, SOURCE)


@pytest.mark.parametrize("failure", ["gate", "checksum", "floor", "producer"])
def test_invalid_existing_index_fails_cli_preflight_without_authorizing_a_rebuild(
    producer, monkeypatch, tmp_path, failure
):
    index = producer.item(f"ci-release-candidate-{SOURCE}")
    if failure == "gate":
        producer.jobs.append(
            {**producer.jobs[0], "id": 999, "run_attempt": 2, "conclusion": "failure"}
        )
    elif failure == "checksum":
        index["digest"] = "sha256:" + "0" * 64
    elif failure == "floor":
        producer.change(
            index["name"], lambda record: record.update(source_floor=CONTROL)
        )
    else:
        index["workflow_run"]["id"] = False
    output = tmp_path / "preflight-outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_release_candidates.py",
            "preflight",
            "--repository",
            REPOSITORY,
            "--source",
            SOURCE,
            "--candidates-only",
        ],
    )
    with pytest.raises(
        ValueError, match="Existing tested candidate evidence failed verification"
    ) as error:
        candidates.main()
    assert not output.exists()
    assert "instead of rebuilding" in str(error.value)
    if failure != "producer":
        assert "Original candidate run 42" in str(error.value)
    assert {
        "gate": "Latest required job",
        "checksum": "ZIP digest",
        "floor": "Candidate index differs",
        "producer": "no valid original producer",
    }[failure] in str(error.value)


@pytest.mark.parametrize("component", candidates.COMPONENTS)
def test_release_pack_and_publish_use_real_cli_parser_and_original_bytes(
    producer, monkeypatch, tmp_path, component
):
    # This invocation is the fixture's producer upload, not the rerun consumer.
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    prefix = tmp_path / component
    output = tmp_path / "cli-upload"
    monkeypatch.setenv("GITHUB_RUN_ID", "42")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_artifacts.py",
            "pack",
            "--component",
            component,
            "--identity",
            SOURCE,
            "--prefix",
            str(prefix),
            "--output",
            str(output),
            "--tier",
            "release",
            "--label",
            "",
        ],
    )
    artifacts.main()
    receipt = json.loads((output / "identity.json").read_text())
    assert receipt["tier"] == "release" and receipt["label"] == ""
    assert receipt["source_commit"] == SOURCE and receipt["source_run_attempt"] == 1
    assert artifacts.digest(output / "payload.tar.gz") == receipt["sha256"]
    with tarfile.open(output / "payload.tar.gz") as payload:
        assert (
            payload.extractfile("payload/application").read()
            == b"compiled fixture, never rebuilt"
        )
    blob = io.BytesIO()
    with zipfile.ZipFile(blob, "w") as upload:
        for member in ("identity.json", "payload.tar.gz"):
            upload.write(output / member, member)
    original = producer.item(artifacts.name(component, SOURCE))
    original["digest"] = "sha256:" + hashlib.sha256(blob.getvalue()).hexdigest()
    producer.blobs[original["id"]] = blob.getvalue()
    sidecar = tmp_path / "cli-sidecar"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_artifacts.py",
            "publish-receipt",
            "--repository",
            REPOSITORY,
            "--component",
            component,
            "--identity",
            SOURCE,
            "--prefix",
            str(output),
            "--artifact-id",
            str(original["id"]),
            "--output",
            str(sidecar),
        ],
    )
    artifacts.main()
    record = json.loads((sidecar / "receipt.json").read_text())
    assert record["source_receipt"] == receipt
    assert (
        record["artifact_id"] == original["id"]
        and record["artifact_digest"] == original["digest"]
    )
    original["name"] = f"main-{component}-{SOURCE}"
    with pytest.raises(ValueError, match="current producer"):
        artifacts.main()


def test_pagination_preserves_every_required_record(monkeypatch):
    responses = iter([{"jobs": list(range(100))}, {"jobs": [100]}])
    calls = []

    def request(repo, route):
        calls.append(route)
        return next(responses)

    monkeypatch.setattr(candidates, "api", request)
    assert candidates.pages(
        REPOSITORY, "actions/runs/42/jobs?filter=all", "jobs"
    ) == list(range(101))
    assert calls[-1].endswith("per_page=100&page=2")


@pytest.mark.parametrize("count", [0, 29, 30, 31, 60, 61, 131])
def test_original_jobs_paginates_complete_structured_rows(monkeypatch, count):
    run = {"id": 42, "head_sha": SOURCE}
    rows = [
        {
            "id": index + 1,
            "run_id": 42,
            "head_sha": SOURCE,
            "name": "candidate-receipt" if index == count - 1 else "linux-test",
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success" if index == count - 1 else "failure",
            "started_at": "2026-10-19T00:00:00Z",
            "completed_at": "2026-10-19T00:01:00Z",
            "steps": [{"name": "Original producer", "conclusion": "success"}],
        }
        for index in range(count)
    ]
    calls = []

    def request(repository, route):
        assert repository == REPOSITORY
        parsed = urlsplit(route)
        assert parsed.path == "actions/runs/42/jobs"
        query = parse_qs(parsed.query)
        assert query["filter"] == ["all"]
        assert query["per_page"] == ["30"]
        page = int(query["page"][0])
        calls.append(page)
        return {"jobs": rows[(page - 1) * 30 : page * 30]}

    monkeypatch.setattr(candidates, "api", request)
    assert candidates.original_jobs(REPOSITORY, run) == rows
    assert calls == list(range(1, count // 30 + 2))


def test_original_jobs_rejects_later_page_failure_without_partial_success(monkeypatch):
    from urllib.error import HTTPError

    rows = [
        {"id": index + 1, "run_attempt": 1, "name": "linux-test"} for index in range(30)
    ]
    calls = []

    def request(repository, route):
        calls.append(route)
        assert "filter=all&per_page=30" in route
        if route.endswith("page=1"):
            return {"jobs": rows}
        assert route.endswith("page=2")
        raise HTTPError(route, 502, "Bad Gateway", {}, None)

    monkeypatch.setattr(candidates, "api", request)
    with pytest.raises(HTTPError, match="502"):
        candidates.original_jobs(REPOSITORY, {"id": 42, "head_sha": SOURCE})
    assert len(calls) == 2


@pytest.mark.parametrize(
    "kwargs",
    [
        {"ref": "refs/pull/987/merge"},
        {"publish_only": True, "candidates_only": True},
        {"candidate_run": -1},
        {"tag": "../../main", "candidates_only": True},
        {"tag": ""},
    ],
)
def test_preflight_invalid_modes_fail_before_any_source_api(producer, kwargs):
    arguments = {"ref": "refs/heads/main", "tag": "v1.2.3", **kwargs}
    producer.requests.clear()
    with pytest.raises(ValueError):
        candidates.preflight(REPOSITORY, CONTROL, **arguments)
    assert not producer.requests


def test_explicit_source_tag_mismatch_and_unstable_source_are_rejected(
    producer, monkeypatch
):
    with pytest.raises(ValueError, match="differs from immutable"):
        candidates.preflight(
            REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3", source=CONTROL
        )
    prior = producer.api

    def request(repo, route):
        if route.startswith("contents/"):
            return {
                "encoding": "base64",
                "content": base64.b64encode(b"version: 1.2.3-dev+4\n").decode(),
            }
        return prior(repo, route)

    monkeypatch.setattr(candidates, "api", request)
    with pytest.raises(ValueError, match="stable version"):
        candidates.source_version(REPOSITORY, SOURCE)


@pytest.mark.parametrize("command", ["preflight", "receipt", "evidence"])
def test_cli_runs_real_byte_proof_before_writing_outputs(
    producer, monkeypatch, tmp_path, command
):
    import sys

    output = tmp_path / "nested" / "evidence.json"
    github_output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(github_output))
    argv = [
        "ci_release_candidates.py",
        command,
        "--repository",
        REPOSITORY,
    ]
    if command in ("preflight", "evidence"):
        producer.index()
        argv += ["--source", SOURCE, "--candidates-only"]
    else:
        # This case executes the fixture's receipt producer, not a consumer.
        monkeypatch.setenv("GITHUB_RUN_ID", "42")
        monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
        producer.run["status"] = "in_progress"
        record = candidates.collect(
            REPOSITORY,
            SOURCE,
            producer.run,
            floor=FLOOR,
            receipt_attempt=1,
            current_run=42,
        )
        outputs = {
            "source": SOURCE,
            **record["components"]["linux-app"]["distribution"],
        }
        for name, platform in (("linux-app", "linux"), ("macos-app", "macos")):
            original = record["components"][name]
            outputs.update(
                {
                    f"{platform}_bundle_id": str(original["artifact_id"]),
                    f"{platform}_bundle_digest": original[
                        "artifact_digest"
                    ].removeprefix("sha256:"),
                    f"{platform}_bundle_attempt": str(original["run_attempt"]),
                }
            )
        monkeypatch.setenv("CANDIDATE_OUTPUTS", json.dumps(outputs))
        argv += ["--source", SOURCE]
    if command != "preflight":
        argv += ["--output", str(output)]
    monkeypatch.setattr(sys, "argv", argv)
    candidates.main()
    if command == "preflight":
        assert "reuse=true\n" in github_output.read_text()
        assert "source=" + SOURCE in github_output.read_text()
        assert not output.exists()
    else:
        value = json.loads(output.read_text())
        assert value["source"] == SOURCE
        if command == "receipt":
            assert value["tested"] is True and value["tier"] == "release"
            assert value["run_id"] == 42
        else:
            assert value["original_runs"] == {
                name: 42 for name in candidates.COMPONENTS
            }
            assert "tested" not in value
            assert value["original_candidate"]["run_id"] == 42
    assert producer.downloads


@pytest.mark.parametrize("command", ["receipt", "evidence"])
def test_cli_refuses_missing_evidence_destination(producer, monkeypatch, command):
    import sys

    producer.requests.clear()
    monkeypatch.setattr(sys, "argv", ["ci_release_candidates.py", command])
    with pytest.raises(SystemExit) as result:
        candidates.main()
    assert result.value.code == 2
    assert not producer.requests


def test_cli_never_forwards_evidence_for_missing_original(
    producer, monkeypatch, tmp_path
):
    import sys

    output = tmp_path / "evidence.json"
    producer.items[:] = [
        item
        for item in producer.items
        if item["name"] != f"ci-release-candidate-{SOURCE}"
    ]
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_release_candidates.py",
            "evidence",
            "--repository",
            REPOSITORY,
            "--source",
            SOURCE,
            "--candidates-only",
            "--output",
            str(output),
        ],
    )
    with pytest.raises(
        ValueError, match="Evidence forwarding requires an existing verified original"
    ):
        candidates.main()
    assert not output.exists()


@pytest.mark.parametrize("minimum", [8, 999])
def test_direct_verifiers_bind_immutable_source_version_floor(
    producer, monkeypatch, minimum
):
    original = candidates.api

    def api(repository, route):
        if route.startswith("contents/"):
            return {
                "encoding": "base64",
                "content": base64.b64encode(
                    f"version: 1.2.3+{minimum}\n".encode()
                ).decode(),
            }
        return original(repository, route)

    monkeypatch.setattr(candidates, "api", api)
    with pytest.raises(ValueError, match="immutable source version"):
        candidates.collect(
            REPOSITORY, SOURCE, producer.run, floor=FLOOR, receipt_attempt=1
        )


@pytest.mark.parametrize("value", [None, "bad", "sha256:" + "g" * 64, True])
def test_noncanonical_artifact_digest_is_never_evidence(value):
    with pytest.raises(ValueError, match="SHA256"):
        candidates.checksum(value)


@pytest.mark.parametrize(
    "mutation",
    [
        lambda record: record.update(schema=True),
        lambda record: record.update(expected_source_floor=CONTROL),
    ],
)
def test_policy_schema_and_frozen_floor_cannot_be_reinterpreted(producer, mutation):
    policy = json.loads(candidates.POLICY.read_text())
    mutation(policy)
    with pytest.raises(ValueError, match="recorded policy"):
        candidates.source_policy(
            REPOSITORY, SOURCE, CONTROL, floor=FLOOR, policy=policy
        )


@pytest.mark.parametrize("record", [[], None, "not an object"])
def test_small_evidence_must_be_a_json_object(producer, record):
    item = producer.add("malformed", zipped("receipt.json", record))
    with pytest.raises(ValueError, match="must be an object"):
        candidates.read_json(REPOSITORY, item, "receipt.json")


@pytest.mark.parametrize("change", [{"size_in_bytes": 65537}, {"expired": True}])
def test_small_receipt_bounds_apply_before_any_download(producer, change):
    item = producer.item(artifacts.receipt_name("linux-app", SOURCE))
    item.update(change)
    producer.downloads.clear()
    with pytest.raises(ValueError, match="live small"):
        candidates.read_json(REPOSITORY, item, "receipt.json")
    assert not producer.downloads


@pytest.mark.parametrize(
    "members",
    [
        [],
        ["other.json"],
        ["receipt.json", "unexpected"],
        ["receipt.json", "receipt.json"],
    ],
)
def test_ambiguous_small_archive_members_are_not_promoted(producer, members):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as bundle:
        for member in members:
            bundle.writestr(member, "{}")
    item = producer.add("malformed", output.getvalue())
    with pytest.raises(ValueError, match="archive members"):
        candidates.read_json(REPOSITORY, item, "receipt.json")


@pytest.mark.parametrize(
    "source,run_id", [("abbreviated", 42), (SOURCE, 0), (SOURCE, True)]
)
def test_verify_rejects_mutable_or_nonpositive_identifiers_before_lookup(
    producer, source, run_id
):
    producer.requests.clear()
    with pytest.raises(ValueError, match="immutable positive"):
        candidates.verify(REPOSITORY, source, run_id)
    assert not producer.requests


@pytest.mark.parametrize(
    "source,run_id", [("abbreviated", 0), (SOURCE, -1), (SOURCE, True)]
)
def test_discovery_rejects_invalid_identifiers_before_lookup(producer, source, run_id):
    producer.requests.clear()
    with pytest.raises(ValueError, match="discovery identifiers"):
        candidates.find(REPOSITORY, source, run_id)
    assert not producer.requests


@pytest.mark.parametrize(
    "runs",
    [
        {},
        {"linux-app": 42},
        {"linux-app": True, "macos-app": 42},
        {"linux-app": 42, "macos-app": 43},
    ],
)
def test_publish_adapter_cannot_mix_candidate_runs(producer, runs):
    with pytest.raises(ValueError, match="both original|share one"):
        candidates.verified_evidence(REPOSITORY, SOURCE, runs)


def test_unencoded_immutable_version_is_not_accepted(producer, monkeypatch):
    monkeypatch.setattr(
        candidates,
        "api",
        lambda *args: {"encoding": "utf8", "content": "version: 1.2.3+4"},
    )
    with pytest.raises(ValueError, match="immutable source version"):
        candidates.source_version(REPOSITORY, SOURCE)


@pytest.mark.parametrize(
    "field,value", [("run_attempt", True), ("run_attempt", 0), ("name", "unrelated")]
)
def test_required_job_identity_cannot_be_ambiguous_or_untyped(field, value):
    jobs = [
        {
            "name": "required",
            "id": 1,
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
        }
    ]
    jobs[0][field] = value
    with pytest.raises(ValueError, match="original job/attempt"):
        candidates.latest(jobs, "required")


@pytest.mark.parametrize("entry", ["preflight", "prepare", "authorize", "evidence"])
def test_retired_below_floor_sources_are_rejected_without_reusing_old_main_bytes(
    producer, monkeypatch, entry
):
    monkeypatch.setenv("RELEASE_SOURCE_FLOOR", "2" * 40)
    producer.downloads.clear()
    with pytest.raises(ValueError, match="below RELEASE_SOURCE_FLOOR"):
        if entry == "preflight":
            candidates.preflight(
                REPOSITORY, CONTROL, ref="refs/heads/main", tag="v1.2.3"
            )
        elif entry == "prepare":
            prepare_release.candidate_runs(REPOSITORY, SOURCE)
        elif entry == "authorize":
            candidates.authorize(REPOSITORY, SOURCE, 42, "linux-app")
        else:
            candidates.verified_evidence(
                REPOSITORY,
                SOURCE,
                {component: 42 for component in candidates.COMPONENTS},
            )
    assert not producer.downloads


def test_default_application_pull_cannot_bypass_the_fully_tested_index(
    producer, tmp_path
):
    index = producer.item(f"ci-release-candidate-{SOURCE}")
    producer.items.remove(index)
    with pytest.raises(ValueError, match="original upload"):
        artifacts.pull(
            REPOSITORY, "linux-app", SOURCE, tmp_path / "untrusted", source_run=42
        )
    assert not (tmp_path / "untrusted").exists()


@pytest.mark.parametrize("field,value", [("build_number", 8), ("version", "9.9.9")])
def test_candidate_index_rejects_mixed_platform_distribution_identity(
    producer, field, value
):
    producer.change(
        artifacts.receipt_name("macos-app", SOURCE),
        lambda record: record["source_receipt"]["distribution"].update({field: value}),
    )
    with pytest.raises(ValueError, match="different stamped identities"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize(
    "foreign",
    [
        {"event": "pull_request", "head_branch": "feature"},
        {"head_repository": {"full_name": "fork/repository"}},
        {"path": ".github/workflows/preview-packages.yml"},
        {"head_branch": "feature"},
        {"event": "push"},
    ],
)
@pytest.mark.parametrize("trusted_index", [False, True])
def test_untrusted_same_named_index_cannot_block_candidate_discovery(
    producer, monkeypatch, foreign, trusted_index
):
    name = f"ci-release-candidate-{SOURCE}"
    if not trusted_index:
        producer.items.remove(producer.item(name))
    item = producer.add(name, b"untrusted bytes must never be downloaded")
    item["workflow_run"] = {"id": 77}
    producer.items.remove(item)
    producer.items.insert(0, item)
    untrusted = {**producer.run, "id": 77, **foreign}
    original = candidates.api

    def api(repository, route):
        if route == "actions/runs/77":
            assert repository == REPOSITORY
            return untrusted
        return original(repository, route)

    monkeypatch.setattr(candidates, "api", api)
    record = candidates.find(REPOSITORY, SOURCE)
    assert (record is not None) == trusted_index
    if trusted_index:
        assert record["run_id"] == 42
    else:
        result = candidates.preflight(
            REPOSITORY,
            CONTROL,
            ref="refs/heads/main",
            source=SOURCE,
            candidates_only=True,
        )
        assert result["reuse"] == "false"
    assert item["id"] not in producer.downloads
    with pytest.raises(
        ValueError, match="Requested fully tested release candidate is unavailable"
    ):
        candidates.find(REPOSITORY, SOURCE, 77)
    assert item["id"] not in producer.downloads


def test_untrusted_index_does_not_hide_invalid_trusted_candidate_evidence(
    producer, monkeypatch
):
    name = f"ci-release-candidate-{SOURCE}"
    producer.change(name, lambda record: record.update(source_floor=CONTROL))
    item = producer.add(name, b"untrusted")
    item["workflow_run"] = {"id": 77}
    producer.items.remove(item)
    producer.items.insert(0, item)
    original = candidates.api

    def api(repository, route):
        if route == "actions/runs/77":
            return {**producer.run, "id": 77, "event": "pull_request"}
        return original(repository, route)

    monkeypatch.setattr(candidates, "api", api)
    with pytest.raises(ValueError, match="Candidate index differs"):
        candidates.find(REPOSITORY, SOURCE)
    assert item["id"] not in producer.downloads


@pytest.mark.parametrize(
    "field,value", [("status", "in_progress"), ("run_attempt", False)]
)
def test_discovery_does_not_ignore_invalid_trusted_controller_identity(
    producer, field, value
):
    producer.run[field] = value
    with pytest.raises(
        ValueError, match="Existing tested candidate evidence failed verification"
    ):
        candidates.find(REPOSITORY, SOURCE)


def test_api_carried_candidates_keep_original_receipt_consumer_and_gate_attempts(
    producer, monkeypatch
):
    original_jobs = list(producer.jobs)
    for job in original_jobs:
        job.update(
            run_id=42,
            head_sha=CONTROL,
            steps=[{"name": "Original upload", "conclusion": "success"}],
        )
    producer.jobs.extend(
        {**job, "id": 10000 + job["id"], "run_attempt": 2} for job in original_jobs
    )
    producer.run["run_attempt"] = 2
    prior = producer.api

    def request(repository, route):
        if route == "actions/runs/42/attempts/2":
            return {
                "id": 42,
                "run_attempt": 2,
                "head_sha": CONTROL,
                "run_started_at": "2026-10-19T00:02:00Z",
            }
        return prior(repository, route)

    monkeypatch.setattr(candidates, "api", request)
    assert candidates.verify(REPOSITORY, SOURCE, 42) == producer.record
    assert (
        candidates.verified_evidence(
            REPOSITORY, SOURCE, {name: 42 for name in candidates.COMPONENTS}
        )["components"]
        == producer.record["components"]
    )
    # A genuinely executed failed job in the newer attempt still revokes the
    # old candidate; the carried successful copy cannot hide it.
    producer.jobs.append(
        {
            **original_jobs[0],
            "id": 20000,
            "run_attempt": 2,
            "conclusion": "failure",
            "started_at": "2026-10-19T00:02:10Z",
            "completed_at": "2026-10-19T00:03:00Z",
        }
    )
    with pytest.raises(ValueError, match="Latest required job"):
        candidates.verify(REPOSITORY, SOURCE, 42)


@pytest.mark.parametrize("component", candidates.COMPONENTS)
@pytest.mark.parametrize("entrypoint", ["pull", "application_descriptor"])
@pytest.mark.parametrize(
    "consumer",
    [
        "release-candidate",
        "legacy-release-candidate",
        "weekly-preview-audit",
        "unknown",
    ],
)
def test_public_app_entrypoints_reject_internal_or_unknown_consumers_before_io(
    producer, tmp_path, entrypoint, consumer, component
):
    producer.requests.clear()
    producer.downloads.clear()
    with pytest.raises(ValueError, match="Unsupported application consumer"):
        if entrypoint == "pull":
            artifacts.pull(
                REPOSITORY,
                component,
                SOURCE,
                tmp_path / "restored",
                source_run=42,
                consumer=consumer,
            )
        else:
            artifacts.application_descriptor(
                REPOSITORY, component, SOURCE, 42, consumer=consumer
            )
    assert not producer.requests
    assert not producer.downloads
    assert not (tmp_path / "restored").exists()


@pytest.mark.parametrize("component", candidates.COMPONENTS)
def test_public_release_preparation_authorizes_before_restoring_real_bytes(
    producer, tmp_path, component
):
    destination = tmp_path / "restored"
    assert artifacts.pull(
        REPOSITORY,
        component,
        SOURCE,
        destination,
        source_run=42,
        consumer="release-preparation",
    )
    assert (
        destination / "application"
    ).read_bytes() == b"compiled fixture, never rebuilt"
    assert artifacts.application_descriptor(
        REPOSITORY, component, SOURCE, 42, consumer="release-preparation"
    ) == {"version": "1.2.3", "build_number": 7}
    assert producer.item(artifacts.name(component, SOURCE))["id"] in producer.downloads


@pytest.mark.parametrize("entrypoint", ["pull", "application_descriptor"])
def test_public_release_preparation_rejects_latest_failed_gate_before_payload(
    producer, tmp_path, entrypoint
):
    producer.jobs.append(
        {**producer.jobs[0], "id": 990, "run_attempt": 2, "conclusion": "failure"}
    )
    producer.downloads.clear()
    with pytest.raises(ValueError, match="Latest required job"):
        if entrypoint == "pull":
            artifacts.pull(
                REPOSITORY,
                "linux-app",
                SOURCE,
                tmp_path / "restored",
                source_run=42,
                consumer="release-preparation",
            )
        else:
            artifacts.application_descriptor(
                REPOSITORY, "linux-app", SOURCE, 42, consumer="release-preparation"
            )
    assert (
        producer.item(artifacts.name("linux-app", SOURCE))["id"]
        not in producer.downloads
    )
    assert not (tmp_path / "restored").exists()


def test_sdk_pull_keeps_existing_consumer_behavior(monkeypatch, tmp_path):
    requests = []
    monkeypatch.setattr(artifacts, "approved_original", lambda *args: None)

    def api(repository, route):
        requests.append((repository, route))
        return {"artifacts": []}

    monkeypatch.setattr(artifacts, "api", api)
    assert not artifacts.pull(
        REPOSITORY, "linux-core", SOURCE, tmp_path / "sdk", consumer="unknown"
    )
    assert requests


def test_authorized_release_pull_still_checks_downloaded_zip_bytes(producer, tmp_path):
    payload = producer.item(artifacts.name("linux-app", SOURCE))
    producer.blobs[payload["id"]] += b"corrupt transport"
    with pytest.raises(ValueError, match="ZIP digest"):
        artifacts.pull(
            REPOSITORY,
            "linux-app",
            SOURCE,
            tmp_path / "restored",
            source_run=42,
            consumer="release-preparation",
        )
    assert payload["id"] in producer.downloads
    assert not (tmp_path / "restored").exists()
@pytest.mark.parametrize(
    "distribution",
    [
        {"version": "1.2.3", "build_number": True},
        {"version": "1.2.3", "build_number": 0},
        {"version": "1.2.3-dev", "build_number": 7},
        {"version": "1.2.3", "build_number": 3},
    ],
)
def test_candidate_index_rejects_invalid_or_below_source_distribution(
    producer, distribution
):
    for component in candidates.COMPONENTS:
        producer.change(
            artifacts.receipt_name(component, SOURCE),
            lambda record: record["source_receipt"].update(distribution=distribution),
        )
    with pytest.raises(
        ValueError, match="distribution identity|immutable source version"
    ):
        candidates.verify(REPOSITORY, SOURCE, 42)
