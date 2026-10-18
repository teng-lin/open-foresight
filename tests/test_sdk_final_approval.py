"""Merged approval qualifies original bytes without rewriting producer history."""

import copy
from unittest.mock import patch

import pytest

from tools import ci_artifacts as artifacts
from tools import sdk_final_approval as approval
from tools import sdk_producer_trust as trust

REPO = "owner/repo"
ORIGINAL = "a" * 40
FINAL = "b" * 40


def run():
    return {
        "id": 42,
        "head_sha": ORIGINAL,
        "head_repository": {"full_name": REPO},
        "path": approval.WORKFLOW,
        "event": "pull_request",
        "pull_requests": [{"number": 119}],
    }


class Evidence:
    def __init__(self):
        self.pull = {
            "merged_at": "2026-10-18T01:00:00Z",
            "head": {"sha": FINAL, "repo": {"full_name": REPO}},
            "base": {"repo": {"full_name": REPO}},
        }
        self.status = "ahead"
        self.members = []
        self.calls = []
        self.approved = True
        self.identities = {ORIGINAL: "same-build", FINAL: "same-build"}
        self.controls = {
            ORIGINAL: {"pack.py": ("100644", b"reviewed")},
            FINAL: {"pack.py": ("100644", b"reviewed")},
        }

    def api(self, repository, path):
        assert repository == REPO
        self.calls.append(path)
        if path == "pulls/119":
            return self.pull
        if path == f"compare/{ORIGINAL}...{FINAL}":
            return {"status": self.status}
        if path.startswith("pulls/119/commits?"):
            page = int(path.rsplit("=", 1)[1])
            return self.members[(page - 1) * 100 : page * 100]
        if path == f"commits/{ORIGINAL}/pulls":
            return [{"number": 119}]
        raise AssertionError(path)

    def merged(self, repository, candidate):
        assert repository == REPO
        assert candidate["head_sha"] == FINAL
        assert candidate["pull_requests"] == [{"number": 119}]
        return self.approved

    def fingerprint(self, repository, commit, component):
        assert repository == REPO and component == "macos-sdk"
        return self.identities[commit]

    def read(self, repository, commit, *, paths):
        assert repository == REPO and paths == ("pack.py",)
        return self.controls[commit]

    def qualify(self, candidate=None, component="macos-sdk"):
        return approval.approved_final_source(
            REPO,
            candidate or run(),
            component,
            api=self.api,
            merged_source=self.merged,
            fingerprint_at=self.fingerprint,
            read_source=self.read,
            controls=("pack.py",),
        )


def test_final_approval_preserves_original_run_and_uses_authoritative_final():
    evidence = Evidence()
    candidate = run()
    original = copy.deepcopy(candidate)
    assert evidence.qualify(candidate)
    assert candidate == original


def test_rebased_history_member_can_qualify_without_ancestry():
    evidence = Evidence()
    evidence.status = "diverged"
    evidence.members = [{"sha": "c" * 40}] * 100 + [{"sha": ORIGINAL}]
    assert evidence.qualify()
    assert "pulls/119/commits?per_page=100&page=2" in evidence.calls


def test_missing_history_is_bounded_and_unqualified():
    evidence = Evidence()
    evidence.status = "diverged"
    evidence.members = [{"sha": "c" * 40}] * 400
    assert not evidence.qualify()
    assert sum("/commits?" in call for call in evidence.calls) == 3


@pytest.mark.parametrize(
    "field,value",
    [
        ("event", "push"),
        ("path", "other.yml"),
        ("head_sha", "bad"),
        ("head_repository", {"full_name": "fork/repo"}),
    ],
)
def test_wrong_producer_boundary_is_rejected(field, value):
    candidate = run()
    candidate[field] = value
    assert not Evidence().qualify(candidate)


@pytest.mark.parametrize("part", ["head", "base"])
def test_fork_pull_metadata_is_rejected(part):
    evidence = Evidence()
    evidence.pull[part]["repo"]["full_name"] = "fork/repo"
    assert not evidence.qualify()


def test_unmerged_or_unapproved_final_does_not_qualify():
    evidence = Evidence()
    evidence.pull["merged_at"] = None
    assert not evidence.qualify()
    evidence.pull["merged_at"] = "merged"
    evidence.approved = False  # Reverted/unreachable or unequal rebase merge tree.
    assert not evidence.qualify()


def test_changed_build_or_control_requires_review_not_cold_build():
    evidence = Evidence()
    evidence.identities[FINAL] = "different-build"
    with pytest.raises(ValueError, match="build inputs differ.*before any rebuild"):
        evidence.qualify()
    evidence.identities[FINAL] = evidence.identities[ORIGINAL]
    evidence.controls[FINAL]["pack.py"] = ("100644", b"changed packer")
    with pytest.raises(
        ValueError, match="producer controls changed.*not a cold rebuild"
    ):
        evidence.qualify()
    evidence.controls[FINAL]["pack.py"] = ("100755", b"reviewed")
    with pytest.raises(ValueError, match="producer controls changed"):
        evidence.qualify()


def test_api_and_deleted_source_failures_propagate():
    evidence = Evidence()
    with patch.object(evidence, "api", side_effect=RuntimeError("network unavailable")):
        with pytest.raises(RuntimeError, match="network unavailable"):
            evidence.qualify()
    with patch.object(
        evidence, "read", side_effect=ValueError("missing required input")
    ):
        with pytest.raises(ValueError, match="missing required input"):
            evidence.qualify()


def test_real_component_identity_ignores_dart_but_tracks_builder(tmp_path):
    # Consumer computes both identities; historical source is never imported.
    component = "macos-sdk"
    for name in artifacts.FILES[component]:
        target = tmp_path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((artifacts.ROOT / name).read_bytes())
    original = artifacts.fingerprint(component, tmp_path)
    dart = tmp_path / "packages/foresight_core/lib/final_fix.dart"
    dart.parent.mkdir(parents=True)
    dart.write_text("// final reviewed application fix\n")
    assert artifacts.fingerprint(component, tmp_path) == original
    builder = tmp_path / "tools/build_macos_sdk.py"
    builder.write_bytes(builder.read_bytes() + b"\n# changed build implementation\n")
    assert artifacts.fingerprint(component, tmp_path) != original


def test_ordinary_receipt_still_requires_original_attempt_and_source():
    candidate = run()
    receipt = {
        "component": "macos-sdk",
        "identity": "same-build",
        "source_commit": ORIGINAL,
        "source_run_attempt": 1,
    }
    job = {
        "name": "Build macOS sdk",
        "conclusion": "success",
        "run_attempt": 1,
        "started_at": "2026-10-18T01:00:00Z",
        "completed_at": "2026-10-18T01:10:00Z",
    }
    payload = {"workflow_run": {"id": 42}, "created_at": "2026-10-18T01:09:00Z"}
    evidence = Evidence()

    def verify():
        return trust.verify_producer_source(
            REPO,
            candidate,
            "macos-sdk",
            "same-build",
            receipt,
            job,
            payload,
            fingerprint_at=evidence.fingerprint,
            qualified_control=lambda *_: evidence.qualify(),
        )

    assert verify()
    receipt["source_commit"] = FINAL
    assert not verify()  # Approval never relabels source provenance.
    receipt["source_commit"] = ORIGINAL
    job["run_attempt"] = 2
    assert not verify()


def test_artifact_integration_reuses_approval_for_eligibility_and_control():
    candidate = run()
    with (
        patch.dict(artifacts.__dict__, {"_APPROVED_FINAL_SDK_SOURCES": set()}),
        patch.object(artifacts, "trusted_run", return_value=False),
        patch.object(artifacts, "merged_source", return_value=False),
        patch.object(approval, "approved_final_source", return_value=True) as qualify,
    ):
        assert artifacts.eligible_run(REPO, candidate, "macos-sdk")
        assert artifacts.qualified_producer_control(REPO, candidate, "macos-sdk")
        assert qualify.call_count == 1
        assert "tools/sdk_final_approval.py" in qualify.call_args.kwargs["controls"]


def test_pending_approval_is_not_cached_forever():
    with (
        patch.dict(artifacts.__dict__, {"_APPROVED_FINAL_SDK_SOURCES": set()}),
        patch.object(
            approval, "approved_final_source", side_effect=[False, True]
        ) as qualify,
    ):
        assert not artifacts.approved_final_sdk_source(REPO, run(), "macos-sdk")
        assert artifacts.approved_final_sdk_source(REPO, run(), "macos-sdk")
        assert qualify.call_count == 2


@pytest.mark.parametrize("operation", ["probe", "pull"])
def test_unqualified_candidate_never_becomes_permission_to_compile(operation, tmp_path):
    identity = "d" * 64
    artifact_name = (
        artifacts.receipt_name("macos-sdk", identity)
        if operation == "probe"
        else artifacts.name("macos-sdk", identity)
    )
    payload = {
        "id": 1,
        "expired": False,
        "name": artifact_name,
        "size_in_bytes": 100,
        "workflow_run": {"id": 42},
    }

    def api(repository, path):
        assert repository == REPO
        if path.startswith("actions/artifacts?"):
            return {"artifacts": [payload]}
        assert path == "actions/runs/42"
        return run()

    with (
        patch.object(artifacts, "approved_original", return_value=None),
        patch.object(artifacts, "api", side_effect=api),
        patch.object(
            artifacts,
            "eligible_run",
            side_effect=ValueError("review control compatibility"),
        ),
        patch.object(artifacts, "download_zip") as download,
    ):
        with pytest.raises(ValueError, match="review control compatibility"):
            if operation == "probe":
                artifacts.probe(REPO, "macos-sdk", identity)
            else:
                artifacts.pull(REPO, "macos-sdk", identity, tmp_path / "prefix")
        download.assert_not_called()


def test_original_head_approval_remains_strictly_separate():
    candidate = run()
    with (
        patch.object(artifacts, "trusted_run", return_value=False),
        patch.object(artifacts, "merged_source", return_value=False),
        patch.object(artifacts, "approved_final_sdk_source", return_value=False),
    ):
        assert not artifacts.eligible_run(REPO, candidate, "macos-sdk")
    # The helper only adds qualification; existing final-head proof is unchanged.
    assert "tools/sdk_final_approval.py" in trust.PRODUCER_CONTROLS
