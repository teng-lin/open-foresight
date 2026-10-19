"""Exercise original bytes through approval, probing, pulling and Linux loading."""

import copy
from dataclasses import replace
import hashlib
import io
import json
import subprocess
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import linux_sdk_artifacts as linux
from tools import sdk_approval_bridge as bridge
from tools.ci_producer_trust import PRODUCERS

REPOSITORY = "owner/repo"
PRODUCER = "a" * 40
FINAL = "b" * 40
MERGE = "c" * 40
SEMANTIC = "d" * 64
IMAGE = "sha256:" + "e" * 64


def test_explicit_sdk_tier_is_not_bypassed_by_the_legacy_approval_bridge(
    original, monkeypatch
):
    assert artifacts.approved_original(REPOSITORY, "linux-core", SEMANTIC)
    original["downloads"].clear()
    monkeypatch.setitem(
        PRODUCERS,
        "dependency-sdk",
        replace(PRODUCERS["dependency-sdk"], receipt_tier="release"),
    )
    assert artifacts.approved_original(REPOSITORY, "linux-core", SEMANTIC) is None
    assert original["downloads"] == []


@pytest.mark.parametrize(
    "field,route",
    [
        ("producer_run", "actions/runs/700"),
        ("artifact_id", "actions/artifacts/700"),
        ("sidecar_id", "actions/artifacts/700"),
    ],
)
@pytest.mark.parametrize("status", [404, 503])
def test_deleted_original_is_skipped_but_api_failures_abort(
    original, monkeypatch, field, route, status
):
    missing = {**original["entry"], field: 700}
    monkeypatch.setattr(bridge, "entries", lambda *args: [missing, original["entry"]])
    previous = artifacts.api

    def api(repository, requested):
        if requested == route:
            raise subprocess.CalledProcessError(
                1, "gh", output=json.dumps({"status": status})
            )
        return previous(repository, requested)

    monkeypatch.setattr(artifacts, "api", api)
    if status == 404:
        assert artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)
        assert original["downloads"] == [6]
    else:
        with pytest.raises(subprocess.CalledProcessError):
            artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)
        assert original["downloads"] == []


@pytest.fixture
def original(tmp_path, monkeypatch):
    definition = (
        "FILES = {'linux-core': ['packaging/sdk-core.Dockerfile']}\n"
        "PRODUCER_INPUTS = ('tools/ci_artifacts.py', 'tools/pins.json')\n"
        "PARENTS = {}\n"
        "raise RuntimeError('producer source must never execute')\n"
    ).encode()
    source = {
        "tools/ci_artifacts.py": ("100644", definition),
        "tools/pins.json": ("100644", b'{"dart":"old"}'),
        "packaging/sdk-core.Dockerfile": ("100644", b"FROM pinned@sha256:abc\n"),
    }
    legacy, proof = bridge.legacy_proof("linux-core", lambda path: source[path][1])
    prefix = tmp_path / "original"
    prefix.mkdir()
    (prefix / "image.tar").write_bytes(b"original Docker image bytes")
    (prefix / "image.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": "linux-core",
                "identity": legacy,
                "transport": "docker-archive",
                "image_id": IMAGE,
                "platform": "linux/amd64",
                "archive_sha256": artifacts.digest(prefix / "image.tar"),
            }
        )
    )

    # Packing remains real; only this fixture's checkout revision is supplied.
    # The archive/receipt tests must also work in source exports without .git.
    def fixture_revision(command, **kwargs):
        assert command == ["git", "rev-parse", "HEAD"]
        assert kwargs == {"cwd": artifacts.ROOT, "text": True, "timeout": 30}
        return PRODUCER

    with monkeypatch.context() as packing:
        packing.setattr(artifacts.subprocess, "check_output", fixture_revision)
        artifacts.pack("linux-core", legacy, prefix, tmp_path / "packed")
    receipt = json.loads((tmp_path / "packed/identity.json").read_text())
    receipt["source_commit"] = "f" * 40  # Historical synthetic merge event SHA.
    (tmp_path / "packed/identity.json").write_text(json.dumps(receipt))
    reference = {
        "schema": 1,
        "component": "linux-core",
        "identity": legacy,
        "artifact_id": 5,
        "source_receipt": receipt,
    }

    def archive(members):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as output:
            for name, content in members.items():
                output.writestr(name, content)
        return stream.getvalue()

    payload_zip = archive(
        {
            name: (tmp_path / "packed" / name).read_bytes()
            for name in ("identity.json", "payload.tar.gz")
        }
    )
    reference["artifact_digest"] = "sha256:" + hashlib.sha256(payload_zip).hexdigest()
    sidecar_zip = archive({"receipt.json": json.dumps(reference).encode()})
    common = {
        "expired": False,
        "workflow_run": {"id": 99},
        "created_at": "2026-10-18T01:00:10Z",
        "expires_at": "2099-01-01T00:00:00Z",
    }
    payload = {
        **common,
        "id": 5,
        "name": artifacts.name("linux-core", legacy),
        "digest": reference["artifact_digest"],
    }
    sidecar = {
        **common,
        "id": 6,
        "name": artifacts.receipt_name("linux-core", legacy),
        "digest": "sha256:" + hashlib.sha256(sidecar_zip).hexdigest(),
        "size_in_bytes": len(sidecar_zip),
    }
    entry = {
        "repository": REPOSITORY,
        "component": "linux-core",
        "semantic_identity": SEMANTIC,
        "legacy_identity": legacy,
        "legacy_inputs": proof,
        "approved_pr": 111,
        "approved_source": FINAL,
        "producer_source": PRODUCER,
        "producer_run": 99,
        "artifact_id": 5,
        "artifact_digest": payload["digest"],
        "sidecar_id": 6,
        "sidecar_digest": sidecar["digest"],
        "source_receipt": receipt,
    }
    run = {
        "id": 99,
        "head_sha": PRODUCER,
        "event": "pull_request",
        "head_branch": "feature",
        "path": ".github/workflows/ci-dependencies.yml",
        "head_repository": {"full_name": REPOSITORY},
        "pull_requests": [{"number": 111}],
    }
    job = {
        "name": "Build Linux core",
        "conclusion": "success",
        "run_attempt": 1,
        "started_at": "2026-10-18T01:00:00Z",
        "completed_at": "2026-10-18T01:01:00Z",
    }
    records = {
        "pulls/111": {
            "merged_at": "2026-10-18",
            "head": {"sha": FINAL},
            "base": {"repo": {"full_name": REPOSITORY}},
            "merge_commit_sha": MERGE,
        },
        f"compare/{PRODUCER}...{FINAL}": {"status": "ahead"},
        "pulls/111/commits?per_page=100&page=1": [{"sha": PRODUCER}],
        f"compare/{FINAL}...main": {"status": "diverged"},
        f"compare/{MERGE}...main": {"status": "ahead"},
        f"git/commits/{FINAL}": {"sha": FINAL, "tree": {"sha": "0" * 40}},
        f"git/commits/{MERGE}": {"sha": MERGE, "tree": {"sha": "0" * 40}},
        "actions/runs/99": run,
        "actions/artifacts/5": payload,
        "actions/artifacts/6": sidecar,
        "actions/runs/99/jobs?filter=all&per_page=100&page=1": {"jobs": [job]},
    }
    manifest = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "MANIFEST", manifest)

    def save():
        manifest.write_text(json.dumps({"schema": 1, "entries": [entry]}))

    save()
    monkeypatch.setattr(
        artifacts, "api", lambda repo, route: records.get(route, {"artifacts": []})
    )
    sources = {PRODUCER: source, FINAL: copy.deepcopy(source)}
    monkeypatch.setattr(
        artifacts.producer_trust,
        "read_source",
        lambda repo, sha, **kwargs: sources[sha],
    )
    monkeypatch.setattr(artifacts, "fingerprint", lambda *args: SEMANTIC)
    downloads = []
    payloads = {5: payload_zip, 6: sidecar_zip}

    def download(arguments, *, stdout, check, timeout, **kwargs):
        artifact_id = int(arguments[-1].split("/")[-2])
        downloads.append(artifact_id)
        stdout.write(payloads[artifact_id])

    monkeypatch.setattr(artifacts.subprocess, "run", download)
    return {
        "entry": entry,
        "records": records,
        "source": sources,
        "save": save,
        "downloads": downloads,
        "root": tmp_path,
        "job": job,
        "payloads": payloads,
    }


def test_exact_original_reuses_through_probe_pull_and_linux_resolve(
    original, monkeypatch
):
    assert artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)
    assert original["downloads"] == [6]  # Probe never transfers the SDK image.
    destination = original["root"] / "restored"
    assert artifacts.pull(REPOSITORY, "linux-core", SEMANTIC, destination)
    assert (
        json.loads((destination / "image.json").read_text())["identity"]
        == original["entry"]["legacy_identity"]
    )
    qualification = json.loads((destination / "approved-source.json").read_text())
    assert (
        qualification["original_source_receipt"] == original["entry"]["source_receipt"]
    )
    assert qualification["approved_source"] == FINAL
    assert linux.record(destination, "linux-core")["image_id"] == IMAGE
    commands = []
    monkeypatch.setattr(
        linux, "run", lambda arguments, **kwargs: commands.append(arguments)
    )
    monkeypatch.setattr(linux, "inspect", lambda image: IMAGE)
    assert linux.resolve(destination, "linux-core") == "foresight-core:pr"
    assert commands[0] == [
        "docker",
        "image",
        "load",
        "--input",
        str(destination / "image.tar"),
    ]
    assert not any("build" in command for command in commands)


@pytest.mark.parametrize(
    "field,value",
    [
        ("approved_source", "0" * 40),
        ("producer_source", "0" * 40),
        ("semantic_identity", "0" * 64),
        ("legacy_identity", "0" * 64),
        ("artifact_digest", "sha256:" + "0" * 64),
        ("producer_run", 88),
    ],
)
def test_manifest_mismatch_cannot_authorize_original(original, field, value):
    original["entry"][field] = value
    original["save"]()
    assert not artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)


@pytest.mark.parametrize(
    "mutation",
    [
        "unmerged",
        "intermediate",
        "nonancestor",
        "unequal_tree",
        "fork",
        "workflow",
        "attempt",
        "late_upload",
        "sidecar_digest",
        "recipe",
        "mode",
    ],
)
def test_each_approval_and_original_provenance_boundary_is_required(original, mutation):
    records = original["records"]
    if mutation == "unmerged":
        records["pulls/111"]["merged_at"] = None
    elif mutation == "intermediate":
        records["pulls/111"]["head"]["sha"] = "1" * 40
    elif mutation == "nonancestor":
        records[f"compare/{MERGE}...main"]["status"] = "diverged"
    elif mutation == "unequal_tree":
        records[f"git/commits/{MERGE}"]["tree"]["sha"] = "1" * 40
    elif mutation == "fork":
        records["actions/runs/99"]["head_repository"]["full_name"] = "fork/repo"
    elif mutation == "workflow":
        records["actions/runs/99"]["path"] = ".github/workflows/other.yml"
    elif mutation == "attempt":
        original["job"]["run_attempt"] = 2
    elif mutation == "late_upload":
        records["actions/artifacts/5"]["created_at"] = "2026-10-18T02:00:00Z"
    elif mutation == "sidecar_digest":
        records["actions/artifacts/6"]["digest"] = "sha256:" + "0" * 64
    elif mutation == "recipe":
        original["source"][FINAL]["packaging/sdk-core.Dockerfile"] = (
            "100644",
            b"changed recipe",
        )
    elif mutation == "mode":
        original["source"][FINAL]["packaging/sdk-core.Dockerfile"] = (
            "100755",
            b"FROM pinned@sha256:abc\n",
        )
    assert not artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)


def test_unmapped_intermediate_head_is_still_rejected(original):
    assert not artifacts.eligible_run(
        REPOSITORY, original["records"]["actions/runs/99"], "linux-core"
    )


def test_descriptor_without_consumer_qualification_is_not_relabelled(original):
    prefix = original["root"] / "original"
    with pytest.raises(ValueError, match="identity or platform"):
        linux.record(prefix, "linux-core")


def test_stacked_original_survives_current_producer_pr_rebase(original):
    entry = original["entry"]
    entry["producer_pr"] = 112
    original["records"]["actions/runs/99"]["pull_requests"] = [
        {"number": 112, "head": {"sha": "9" * 40}}
    ]
    # The original source is no longer in the rebased PR112 history. Its full
    # compiler/control input proof equals the approved final PR111 source.
    original["records"].pop(f"compare/{PRODUCER}...{FINAL}")
    original["records"].pop("pulls/111/commits?per_page=100&page=1")
    original["save"]()
    assert artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)
    original["records"]["actions/runs/99"]["pull_requests"] = []
    assert artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)


def test_reused_bridge_never_relabels_or_reuploads_the_original(original, monkeypatch):
    monkeypatch.setattr(
        artifacts, "pack", lambda *args: pytest.fail("must retain original receipt")
    )
    monkeypatch.setattr(
        linux.sdk_build_transport,
        "prepare",
        lambda *args, **kwargs: pytest.fail("must not provision a compiler"),
    )
    output = original["root"] / "should-not-upload"
    assert linux.produce("linux-core", output, REPOSITORY) == "approved-original"
    assert not output.exists()


def test_ordinary_payload_cannot_import_legacy_approval(original, monkeypatch):
    prefix = original["root"] / "original"
    entry = original["entry"]
    (prefix / "approved-source.json").write_text(
        json.dumps(bridge.qualification(entry, prefix, artifacts.digest))
    )
    monkeypatch.setattr(
        artifacts.subprocess, "check_output", lambda *args, **kwargs: PRODUCER
    )
    packed = original["root"] / "forged"
    artifacts.pack("linux-core", SEMANTIC, prefix, packed)
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as output:
        for name in ("identity.json", "payload.tar.gz"):
            output.write(packed / name, name)
    payload = original["records"]["actions/artifacts/5"]
    payload["name"] = artifacts.name("linux-core", SEMANTIC)
    payload["digest"] = "sha256:" + hashlib.sha256(stream.getvalue()).hexdigest()
    original["payloads"][5] = stream.getvalue()
    original["records"][f"actions/artifacts?name={payload['name']}&per_page=100"] = {
        "artifacts": [payload]
    }
    monkeypatch.setattr(bridge, "entries", lambda *args: [])
    monkeypatch.setattr(artifacts, "source_fingerprint_at", lambda *args: SEMANTIC)
    monkeypatch.setattr(artifacts, "qualified_producer_control", lambda *args: True)
    with pytest.raises(ValueError, match="imported approval"):
        artifacts.pull(
            REPOSITORY,
            "linux-core",
            SEMANTIC,
            original["root"] / "ordinary",
            own_pr=111,
        )


def test_pack_binds_actual_checkout_and_retains_qualification_receipt(
    tmp_path, monkeypatch
):
    prefix = tmp_path / "prefix"
    prefix.mkdir()
    original_receipt = {
        "source_receipt": {"source_commit": "e" * 40},
        "artifact_id": 123,
    }
    (prefix / "source-qualification.json").write_text(json.dumps(original_receipt))
    monkeypatch.setenv("GITHUB_SHA", "f" * 40)
    monkeypatch.setattr(
        artifacts.subprocess, "check_output", lambda *args, **kwargs: PRODUCER
    )
    artifacts.pack("linux-core", SEMANTIC, prefix, tmp_path / "output")
    receipt = json.loads((tmp_path / "output/identity.json").read_text())
    assert receipt["source_commit"] == PRODUCER
    assert receipt["reused_from"] == original_receipt


def test_cli_reports_original_without_requesting_payload_upload(tmp_path, monkeypatch):
    monkeypatch.setattr(linux, "produce", lambda *args, **kwargs: "approved-original")
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        "sys.argv",
        [
            "linux_sdk_artifacts.py",
            "produce",
            "--component",
            "linux-core",
            "--output",
            str(tmp_path / "unused"),
        ],
    )
    linux.main()
    assert output.read_text() == "original=true\n"


@pytest.mark.parametrize("pin", ["exact", "foreign-id", "foreign-run", "bad-digest"])
def test_exact_artifact_pin_revalidates_original_without_selecting_another(
    original, monkeypatch, pin
):
    entry = original["entry"]
    options = {
        "artifact_id": entry["artifact_id"],
        "artifact_digest": entry["artifact_digest"],
        "source_run": entry["producer_run"],
    }
    if pin == "foreign-id":
        options["artifact_id"] = 700
    elif pin == "foreign-run":
        options["source_run"] = 700
    elif pin == "bad-digest":
        options["artifact_digest"] = "sha256:" + "0" * 64
    original["records"]["actions/artifacts/700"] = {
        **original["records"]["actions/artifacts/5"],
        "id": 700,
    }
    destination = original["root"] / "pinned"
    if pin == "exact":
        assert artifacts.pull(
            REPOSITORY, "linux-core", SEMANTIC, destination, **options
        )
        assert (
            destination / "image.tar"
        ).read_bytes() == b"original Docker image bytes"
        assert original["downloads"] == [6, 5]
    elif pin == "bad-digest":
        with pytest.raises(ValueError, match="ID/digest"):
            artifacts.pull(REPOSITORY, "linux-core", SEMANTIC, destination, **options)
        assert not destination.exists()
    else:
        assert not artifacts.pull(
            REPOSITORY, "linux-core", SEMANTIC, destination, **options
        )
        assert not destination.exists()
        assert 5 not in original["downloads"]


@pytest.mark.parametrize(
    "options",
    [
        {"artifact_id": 5},
        {"artifact_digest": "sha256:" + "a" * 64},
        {"artifact_id": -1, "artifact_digest": "bad"},
    ],
)
def test_incomplete_pins_fail_before_network(tmp_path, monkeypatch, options):
    monkeypatch.setattr(
        artifacts, "api", lambda *args: pytest.fail("Invalid pin reached network")
    )
    with pytest.raises(ValueError, match="pin requires"):
        artifacts.pull(
            REPOSITORY, "linux-sdk", SEMANTIC, tmp_path / "invalid", **options
        )


@pytest.mark.parametrize(
    "change", ["none", "failed-job", "late-upload", "corrupt-zip", "wrong-run"]
)
def test_ordinary_pin_keeps_original_sdk_even_with_newer_producer(
    original, monkeypatch, change
):
    entry = original["entry"]
    run = original["records"]["actions/runs/99"]
    run.update(head_sha="f" * 40, head_branch="main", event="push")
    monkeypatch.setattr(artifacts, "approved_original", lambda *args: None)
    monkeypatch.setattr(
        artifacts, "source_fingerprint_at", lambda *args: entry["legacy_identity"]
    )
    monkeypatch.setattr(artifacts, "qualified_producer_control", lambda *args: True)
    original["records"][
        "actions/artifacts?name="
        + artifacts.name("linux-core", entry["legacy_identity"])
        + "&per_page=100"
    ] = {
        "artifacts": [
            {
                **original["records"]["actions/artifacts/5"],
                "id": 700,
                "workflow_run": {"id": 700},
            },
            original["records"]["actions/artifacts/5"],
        ]
    }
    if change == "failed-job":
        original["job"]["conclusion"] = "failure"
    elif change == "late-upload":
        original["records"]["actions/artifacts/5"]["created_at"] = (
            "2026-10-18T02:00:00Z"
        )
    elif change == "corrupt-zip":
        original["payloads"][5] += b"corrupt"
    elif change == "wrong-run":
        original["records"]["actions/artifacts/5"]["workflow_run"]["id"] = 700
    destination = original["root"] / "ordinary-pinned"
    options = {
        "source_run": 99,
        "artifact_id": 5,
        "artifact_digest": entry["artifact_digest"],
    }
    if change == "corrupt-zip":
        with pytest.raises(ValueError):
            artifacts.pull(
                REPOSITORY,
                "linux-core",
                entry["legacy_identity"],
                destination,
                **options,
            )
    else:
        hit = artifacts.pull(
            REPOSITORY, "linux-core", entry["legacy_identity"], destination, **options
        )
        assert hit == (change == "none")
    if change == "none":
        assert (
            json.loads((destination / "source-qualification.json").read_text())[
                "artifact_id"
            ]
            == 5
        )
        assert original["downloads"] == [5]
    else:
        assert not destination.exists()


@pytest.mark.parametrize("prior_wait", [False, True])
@pytest.mark.parametrize("outcome", ["success", "failure", "expired", "corrupt-zip"])
def test_internal_wait_completion_race_requalifies_original_zip(
    original, monkeypatch, prior_wait, outcome
):
    entry = original["entry"]
    original["records"]["actions/runs/99"].update(
        head_sha="f" * 40, head_branch="main", event="push"
    )
    original["job"]["conclusion"] = None
    monkeypatch.setattr(artifacts, "approved_original", lambda *args: None)
    monkeypatch.setattr(
        artifacts, "source_fingerprint_at", lambda *args: entry["legacy_identity"]
    )
    monkeypatch.setattr(artifacts, "qualified_producer_control", lambda *args: True)
    lookups, statuses, delays = [], [], []
    request = artifacts.api

    def api(repo, route):
        if route == "actions/artifacts/5":
            lookups.append(route)
        return request(repo, route)

    monkeypatch.setattr(artifacts, "api", api)

    def waiting(*args):
        statuses.append(args)
        if prior_wait and len(statuses) == 1:
            return [99]
        original["job"]["conclusion"] = "failure" if outcome == "failure" else "success"
        if outcome == "expired":
            original["records"]["actions/artifacts/5"]["expired"] = True
        elif outcome == "corrupt-zip":
            original["payloads"][5] += b"corrupt"
        return []

    monkeypatch.setattr(artifacts, "waiting_for_dependency", waiting)
    monkeypatch.setattr(artifacts.time, "monotonic", lambda: 0)
    monkeypatch.setattr(artifacts.time, "sleep", delays.append)
    destination = original["root"] / "completion-pinned"
    options = dict(
        wait=1800,
        own_head="f" * 40,
        own_pr=0,
        source_run=99,
        artifact_id=5,
        artifact_digest=entry["artifact_digest"],
    )
    if outcome == "corrupt-zip":
        with pytest.raises(ValueError, match="ZIP digest"):
            artifacts.pull(
                REPOSITORY,
                "linux-core",
                entry["legacy_identity"],
                destination,
                **options,
            )
    else:
        assert artifacts.pull(
            REPOSITORY, "linux-core", entry["legacy_identity"], destination, **options
        ) == (outcome == "success")
    assert len(lookups) == (3 if prior_wait else 2)
    assert len(statuses) == (2 if prior_wait else 1)
    assert delays == ([60] if prior_wait else [])
    if outcome == "success":
        assert original["downloads"] == [5]
        assert (
            destination / "image.tar"
        ).read_bytes() == b"original Docker image bytes"
        proof = json.loads((destination / "source-qualification.json").read_text())
        assert (
            proof["artifact_id"] == 5
            and proof["source_receipt"] == entry["source_receipt"]
        )
    else:
        assert not destination.exists()
