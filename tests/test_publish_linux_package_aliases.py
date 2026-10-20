"""Alias publication must use qualified current-main images and preserve digests."""

import copy
from dataclasses import replace
import hashlib
import io
import json
import os
import subprocess
import unittest
from unittest.mock import patch
import zipfile

import pytest

from tools import publish_linux_package_aliases as aliases
from tools.ci_producer_trust import PRODUCERS

REPOSITORY = "teng-lin/open-foresight"
HEAD = "a" * 40
DIGEST = "sha256:" + "b" * 64


class AliasTests(unittest.TestCase):
    def command_output(self, command, **kwargs):
        if command[:2] == ["git", "rev-parse"]:
            return HEAD
        return json.dumps({"sha": HEAD})

    def image(self, component):
        return f"ghcr.io/{REPOSITORY}/{component}@{DIGEST}"

    def test_publishes_and_verifies_each_qualified_image(self):
        with (
            patch.object(
                aliases.subprocess, "check_output", side_effect=self.command_output
            ),
            patch.object(
                aliases,
                "published_descriptor",
                side_effect=lambda repo, component, identity: {
                    "image": self.image(component)
                },
            ) as pull,
            patch.object(aliases.subprocess, "run") as publish,
            patch.object(
                aliases.registry,
                "inspect",
                side_effect=lambda alias: alias.removesuffix(":current") + "@" + DIGEST,
            ),
        ):
            aliases.publish(REPOSITORY)
        self.assertEqual(pull.call_count, 4)
        self.assertTrue(all(call.args[0] == REPOSITORY for call in pull.call_args_list))
        self.assertEqual(publish.call_count, 4)
        for component, call in zip(
            aliases.COMPONENTS, publish.call_args_list, strict=True
        ):
            self.assertIn("--prefer-index=false", call.args[0])
            self.assertEqual(
                call.args[0][-2:],
                [f"ghcr.io/{REPOSITORY}/{component}:current", self.image(component)],
            )

    def test_main_advancing_stops_before_publication(self):
        for outputs in (
            (HEAD, json.dumps({"sha": "c" * 40})),
            (HEAD, json.dumps({"sha": HEAD}), json.dumps({"sha": "c" * 40})),
        ):
            with (
                patch.object(aliases.subprocess, "check_output", side_effect=outputs),
                patch.object(
                    aliases,
                    "published_descriptor",
                    return_value={"image": self.image("linux-core")},
                ),
                patch.object(aliases.subprocess, "run") as publish,
            ):
                with self.assertRaisesRegex(RuntimeError, "Main advanced"):
                    aliases.publish(REPOSITORY)
                publish.assert_not_called()

    def test_unqualified_missing_or_foreign_sources_cannot_publish(self):
        for descriptor in (
            None,
            {"transport": "docker-archive"},
            {"image": "ghcr.io/other/project/linux-core@" + DIGEST},
        ):
            with (
                patch.object(
                    aliases.subprocess, "check_output", side_effect=self.command_output
                ),
                patch.object(
                    aliases,
                    "published_descriptor",
                    return_value=descriptor,
                    side_effect=RuntimeError("Published descriptor unavailable")
                    if descriptor is None
                    else None,
                ),
                patch.object(aliases.subprocess, "run") as publish,
            ):
                with self.assertRaises((ValueError, RuntimeError)):
                    aliases.publish(REPOSITORY)
                publish.assert_not_called()

    def test_failed_push_or_digest_mismatch_cannot_report_success(self):
        for error in (subprocess.CalledProcessError(1, ["docker"]), None):
            with (
                patch.object(
                    aliases.subprocess, "check_output", side_effect=self.command_output
                ),
                patch.object(
                    aliases,
                    "published_descriptor",
                    return_value={"image": self.image("linux-core")},
                ),
                patch.object(aliases.subprocess, "run", side_effect=error),
                patch.object(
                    aliases.registry,
                    "inspect",
                    return_value=self.image("linux-whisper"),
                ),
            ):
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    aliases.publish(REPOSITORY)


@pytest.fixture
def published(tmp_path, monkeypatch):
    a = aliases.artifacts
    component = "linux-core"
    identity = a.fingerprint(component)
    source = "c" * 40
    prefix = tmp_path / "payload"
    prefix.mkdir()
    (prefix / "image.json").write_text(
        json.dumps({"image": f"ghcr.io/{REPOSITORY}/{component}@{DIGEST}"})
    )
    history = {"source_receipt": {"source_commit": "e" * 40}, "producer_run": 19}
    (prefix / "source-qualification.json").write_text(json.dumps(history))
    packed = tmp_path / "packed"
    with (
        patch.object(a.subprocess, "check_output", return_value=source + "\n"),
        patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
    ):
        a.pack(component, identity, prefix, packed)
    receipt = json.loads((packed / "identity.json").read_text())
    state = {"receipt": receipt, "payload": (packed / "payload.tar.gz").read_bytes()}
    artifact = {
        "id": 20,
        "name": a.name(component, identity),
        "size_in_bytes": 1000,
        "expired": False,
        "workflow_run": {"id": 7},
        "created_at": "2026-01-01T00:05:00Z",
    }
    run = {
        "id": 7,
        "path": a.WORKFLOW,
        "head_sha": source,
        "event": "push",
        "head_branch": "main",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
    }
    job = {
        "name": a.JOBS[component],
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        "started_at": "2026-01-01T00:00:00Z",
        "completed_at": "2026-01-01T00:10:00Z",
    }
    state.update(
        component=component,
        identity=identity,
        artifact=artifact,
        run=run,
        job=job,
        downloaded=[],
        items=[artifact],
        blobs={},
    )

    def seal():
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as stream:
            stream.writestr("identity.json", json.dumps(state["receipt"]))
            stream.writestr("payload.tar.gz", state["payload"])
        data = buffer.getvalue()
        state["blobs"][20] = data
        artifact["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()

    seal()
    state["seal"] = seal

    def api(repository, route):
        assert repository == REPOSITORY
        if route.startswith("actions/artifacts?"):
            assert f"name={artifact['name']}" in route
            if state.get("pagination"):
                if route.endswith("page=1"):
                    return {
                        "artifacts": [
                            dict(artifact, id=1000 + i, expired=True)
                            for i in range(100)
                        ]
                    }
                assert route.endswith("page=2")
            return {"artifacts": state["items"]}
        if route == "actions/runs/7":
            return run
        if route == "actions/runs/7/jobs?filter=all&per_page=30&page=1":
            return {"jobs": [job]}
        if route == f"compare/{source}...main":
            return {"status": "identical"}
        raise AssertionError(route)

    def command(command, stdout, check, timeout, stderr):
        assert command[:2] == ["gh", "api"]
        number = int(command[-1].split("/")[-2])
        state["downloaded"].append(number)
        stdout.write(state["blobs"][number])
        return subprocess.CompletedProcess(command, 0)

    def fingerprint(repository, commit, name):
        assert (repository, commit, name) == (REPOSITORY, source, component)
        return state.get("remote_identity", identity)

    monkeypatch.setattr(a, "api", api)
    monkeypatch.setattr(a, "source_fingerprint_at", fingerprint)
    monkeypatch.setattr(a.subprocess, "run", command)
    monkeypatch.setattr(
        a,
        "approved_original",
        lambda *args: pytest.fail("Alias must not retrieve archive originals"),
    )
    return state


def resolve(published):
    return aliases.published_descriptor(
        REPOSITORY, published["component"], published["identity"]
    )


def test_alias_receipt_tier_is_independent_and_enforced(published, monkeypatch):
    monkeypatch.setitem(
        PRODUCERS,
        "package-alias",
        replace(PRODUCERS["package-alias"], receipt_tier="release"),
    )
    with pytest.raises(ValueError, match="alias receipt tier"):
        resolve(published)
    published["receipt"]["tier"] = "release"
    published["seal"]()
    assert resolve(published)


def test_alias_consumer_checks_its_own_producer_job(published, monkeypatch):
    row = PRODUCERS["package-alias"]
    jobs = dict(row.jobs)
    jobs[published["component"]] = ("new reviewed alias publisher",)
    monkeypatch.setitem(PRODUCERS, "package-alias", replace(row, jobs=jobs))
    with pytest.raises(RuntimeError, match="descriptor unavailable"):
        resolve(published)


def test_real_registry_envelope_preserves_history_and_avoids_original_archives(
    published,
):
    assert resolve(published) == {"image": f"ghcr.io/{REPOSITORY}/linux-core@{DIGEST}"}
    assert published["downloaded"] == [20]
    assert (
        published["receipt"]["reused_from"]["source_receipt"]["source_commit"]
        == "e" * 40
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("event", "pull_request"),
        ("head_branch", "feature"),
        ("path", ".github/workflows/other.yml"),
        ("repository", {"full_name": "other/repo"}),
        ("head_repository", {"full_name": "other/repo"}),
    ],
)
def test_foreign_or_pr_producers_never_supply_alias_descriptors(
    published, field, value
):
    published["run"][field] = value
    with pytest.raises(RuntimeError, match="descriptor unavailable"):
        resolve(published)
    assert not published["downloaded"]


@pytest.mark.parametrize(
    "change", ["attempt", "failed", "running", "upload", "source", "inputs"]
)
def test_successful_original_attempt_source_and_inputs_are_required(published, change):
    if change == "attempt":
        published["job"]["run_attempt"] = 2
    if change == "failed":
        published["job"]["conclusion"] = "failure"
    if change == "running":
        published["job"]["status"] = "in_progress"
    if change == "upload":
        published["artifact"]["created_at"] = "2026-01-01T00:11:00Z"
    if change == "source":
        published["receipt"]["source_commit"] = "d" * 40
        published["seal"]()
    if change == "inputs":
        published["remote_identity"] = "d" * 64
    with pytest.raises(RuntimeError, match="descriptor unavailable"):
        resolve(published)


def test_unapproved_controls_propagate_without_authorizing_a_build(
    published, monkeypatch
):
    monkeypatch.setattr(
        aliases.artifacts, "qualified_producer_control", lambda *args: False
    )
    with pytest.raises(ValueError, match="controls are not qualified"):
        resolve(published)


@pytest.mark.parametrize("change", ["zip", "payload", "members"])
def test_transport_and_payload_integrity_remain_independent(published, change):
    if change == "zip":
        published["blobs"][20] += b"tampered"
    elif change == "payload":
        published["payload"] += b"tampered"
        published["seal"]()
    else:
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as stream:
            stream.writestr("../escape", b"unsafe")
        published["blobs"][20] = data.getvalue()
        published["artifact"]["digest"] = (
            "sha256:" + hashlib.sha256(data.getvalue()).hexdigest()
        )
    with pytest.raises(ValueError, match="ZIP|payload checksum"):
        resolve(published)


def test_large_legacy_archive_is_not_downloaded_and_history_is_paginated(published):
    large = dict(
        published["artifact"], id=21, size_in_bytes=aliases.MAX_DESCRIPTOR_BYTES + 1
    )
    published["items"] = [large, published["artifact"]]
    published["pagination"] = True
    assert resolve(published)["image"].endswith(DIGEST)
    assert published["downloaded"] == [20]


def test_small_archive_transport_cannot_hide_a_later_registry_descriptor(
    published, tmp_path
):
    import tarfile

    a = aliases.artifacts
    raw = tmp_path / "raw.tar.gz"
    with tarfile.open(raw, "w:gz") as stream:
        blob = json.dumps({"transport": "docker-archive"}).encode()
        entry = tarfile.TarInfo("payload/image.json")
        entry.size = len(blob)
        stream.addfile(entry, io.BytesIO(blob))
        entry = tarfile.TarInfo("payload/image.tar")
        entry.size = 4
        stream.addfile(entry, io.BytesIO(b"SDK!"))
    receipt = copy.deepcopy(published["receipt"])
    receipt["sha256"] = a.digest(raw)
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as stream:
        stream.writestr("identity.json", json.dumps(receipt))
        stream.writestr("payload.tar.gz", raw.read_bytes())
    archived = dict(
        published["artifact"],
        id=21,
        digest="sha256:" + hashlib.sha256(data.getvalue()).hexdigest(),
    )
    published["blobs"][21] = data.getvalue()
    published["items"] = [archived, published["artifact"]]
    assert resolve(published)["image"].endswith(DIGEST)
    assert published["downloaded"] == [21, 20]


def test_api_failure_stops_without_publication_or_rebuild(published, monkeypatch):
    monkeypatch.setattr(
        aliases.artifacts,
        "api",
        lambda *args: (_ for _ in ()).throw(subprocess.CalledProcessError(1, "gh")),
    )
    with pytest.raises(subprocess.CalledProcessError):
        resolve(published)
