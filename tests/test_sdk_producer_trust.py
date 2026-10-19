"""Producer claims cannot substitute for immutable inputs or successful work."""

import base64
import hashlib
from unittest.mock import patch

import pytest

from tools import sdk_producer_trust as trust
from tools import ci_macos_dependencies as macos

HEAD = "a" * 40
IDENTITY = "b" * 64


def producer():
    run = {
        "id": 10,
        "head_sha": HEAD,
        "path": trust.WORKFLOW,
        "head_repository": {"full_name": "owner/repo"},
    }
    receipt = {
        "component": "macos-sdk",
        "identity": IDENTITY,
        "source_commit": HEAD,
        "source_run_attempt": 1,
    }
    job = {
        "name": "Build macOS sdk",
        "conclusion": "success",
        "run_attempt": 1,
        "started_at": "2026-10-18T01:00:00Z",
        "completed_at": "2026-10-18T01:10:00Z",
    }
    artifact = {"workflow_run": {"id": 10}, "created_at": "2026-10-18T01:09:00Z"}
    return run, receipt, job, artifact


def verified(run, receipt, job, artifact, **kwargs):
    return trust.verify_producer_source(
        "owner/repo",
        run,
        "macos-sdk",
        IDENTITY,
        receipt,
        job,
        artifact,
        fingerprint_at=kwargs.pop("fingerprint_at", lambda *args: IDENTITY),
        qualified_control=kwargs.pop("qualified_control", lambda *args: True),
        **kwargs,
    )


def test_matching_receipt_requires_actual_source_recipe():
    values = producer()
    assert verified(*values)
    assert not verified(*values, fingerprint_at=lambda *args: "c" * 64)
    values[1]["source_commit"] = "d" * 40
    assert not verified(*values)


def test_unqualified_producer_is_not_silently_treated_as_cold_build_permission():
    with pytest.raises(ValueError, match="does not authorize a cold SDK build"):
        verified(*producer(), qualified_control=lambda *args: False)


def test_control_identity_is_separate_from_build_recipe(tmp_path):
    path = tmp_path / "pack.py"
    path.write_bytes(b"reviewed producer")
    assert trust.producer_controls_match(
        "owner/repo",
        HEAD,
        api=git_api({"pack.py": b"reviewed producer"}),
        root=tmp_path,
        paths=("pack.py",),
    )
    assert not trust.producer_controls_match(
        "owner/repo",
        HEAD,
        api=git_api({"pack.py": b"fabricate a receipt"}),
        root=tmp_path,
        paths=("pack.py",),
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("created_at", "2026-10-18T02:09:00Z"),
        ("created_at", "2026-10-18T00:59:00Z"),
        ("created_at", "invalid"),
        ("workflow_run", {"id": 11}),
    ],
)
def test_failed_or_unrelated_attempt_cannot_claim_earlier_success(field, value):
    values = producer()
    values[3][field] = value
    assert not verified(*values)


def test_legacy_exception_preserves_synthetic_receipt_but_not_attempt_checks():
    values = producer()
    values[1]["source_commit"] = "e" * 40  # Historical PR synthetic event SHA.
    assert verified(*values, approved_legacy=lambda *args: True)
    values[2]["run_attempt"] = 2
    assert not verified(*values, approved_legacy=lambda *args: True)


@pytest.mark.parametrize(
    "field,value",
    [("conclusion", "failure"), ("name", "Other job"), ("run_attempt", 2)],
)
def test_exact_successful_component_attempt_required(field, value):
    values = producer()
    values[2][field] = value
    assert not verified(*values)


def git_api(contents, *, corrupt=False, truncated=False, mode="100644", commit=HEAD):
    tree_sha = "f" * 40
    objects = {}
    entries = []
    for name, data in contents.items():
        sha = hashlib.sha1(
            b"blob " + str(len(data)).encode() + b"\0" + data, usedforsecurity=False
        ).hexdigest()
        entries.append({"path": name, "type": "blob", "mode": mode, "sha": sha})
        objects[sha] = {
            "sha": sha,
            "encoding": "base64",
            "size": len(data),
            "content": base64.b64encode(data + (b"bad" if corrupt else b"")).decode(),
        }

    def api(repository, route):
        assert repository == "owner/repo"
        if route == f"git/commits/{commit}":
            return {"sha": commit, "tree": {"sha": tree_sha}}
        if route == f"git/trees/{tree_sha}?recursive=1":
            return {"sha": tree_sha, "truncated": truncated, "tree": entries}
        return objects[route.removeprefix("git/blobs/")]

    return api


def test_source_loader_uses_consumer_recipe_and_includes_new_headers():
    contents = {
        "recipe.py": b"raise RuntimeError('must never execute')",
        "parent.txt": b"parent",
        "services/speech/new.h": b"header",
    }

    def fingerprint(component, root):
        assert component == "macos-runtime"
        assert (root / "recipe.py").read_bytes() == contents["recipe.py"]
        assert (root / "parent.txt").read_bytes() == b"parent"
        return (root / "services/speech/new.h").read_bytes().decode()

    assert (
        trust.source_fingerprint(
            "owner/repo",
            HEAD,
            "macos-runtime",
            api=git_api(contents),
            fingerprint=fingerprint,
            files={"macos-runtime": ["recipe.py"], "macos-vendor": ["parent.txt"]},
            parents={"macos-runtime": ["macos-vendor"]},
        )
        == "header"
    )


@pytest.mark.parametrize(
    "options", [{"corrupt": True}, {"truncated": True}, {"mode": "120000"}]
)
def test_source_loader_rejects_unverifiable_git_inputs(options):
    with pytest.raises(ValueError):
        trust.read_source(
            "owner/repo",
            HEAD,
            api=git_api({"recipe.py": b"data"}, **options),
            paths={"recipe.py"},
        )


def test_missing_required_input_is_not_a_valid_old_recipe():
    with pytest.raises(ValueError, match="missing required"):
        trust.read_source("owner/repo", HEAD, api=git_api({}), paths={"recipe.py"})


def test_legacy_controls_do_not_require_an_unconsumed_new_table():
    paths = ("packer.py", trust.TRUST_TABLE)
    assert trust.read_producer_controls(
        "owner/repo",
        HEAD,
        api=git_api({"packer.py": b"reviewed"}),
        paths=paths,
    ) == {"packer.py": ("100644", b"reviewed")}
    with pytest.raises(ValueError, match="missing required"):
        trust.read_producer_controls("owner/repo", HEAD, api=git_api({}), paths=paths)
    with pytest.raises(ValueError, match="missing required"):
        trust.read_source(
            "owner/repo", HEAD, api=git_api({"packer.py": b"reviewed"}), paths=paths
        )


@pytest.mark.parametrize(
    "reference",
    [
        b"from tools.ci_producer_trust import PRODUCERS",
        b"from tools import ci_producer_trust",
        b'importlib.import_module("tools.ci_producer_trust")',
        b'Path("tools/ci_producer_trust.py").read_bytes()',
    ],
)
def test_consumed_table_cannot_be_omitted(reference):
    with pytest.raises(ValueError, match="references a missing producer trust table"):
        trust.read_producer_controls(
            "owner/repo",
            HEAD,
            api=git_api({"packer.py": reference}),
            paths=("packer.py", trust.TRUST_TABLE),
        )


@pytest.mark.parametrize(
    "options", [{"corrupt": True}, {"truncated": True}, {"mode": "120000"}]
)
def test_conditional_table_keeps_git_integrity_checks(options):
    with pytest.raises(ValueError):
        trust.read_producer_controls(
            "owner/repo",
            HEAD,
            api=git_api({trust.TRUST_TABLE: b"reviewed"}, **options),
            paths=(trust.TRUST_TABLE,),
        )


def test_compatible_running_earlier_head_is_preserved_and_current_rerun_selected():
    run = {"id": 10, "head_sha": HEAD, "status": "in_progress", "run_attempt": 2}
    jobs = [
        {"name": "Build macOS sdk", "conclusion": "failure", "run_attempt": 1},
        {"name": "Build macOS sdk", "conclusion": None, "run_attempt": 2},
    ]
    assert trust.compatible_producers(
        "owner/repo",
        [run],
        "macos-sdk",
        IDENTITY,
        eligible=lambda run: True,
        jobs=lambda *args: jobs,
        fingerprint_at=lambda *args: IDENTITY,
    ) == [10]
    assert (
        trust.compatible_producers(
            "owner/repo",
            [run],
            "macos-sdk",
            IDENTITY,
            eligible=lambda run: False,
            jobs=lambda *args: jobs,
            fingerprint_at=lambda *args: IDENTITY,
        )
        == []
    )


def test_compatible_producer_deadline_never_starts_duplicate_compiler(tmp_path):
    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value=IDENTITY),
        patch.object(macos, "waiting_producers", return_value=[10]),
        patch.object(macos.subprocess, "run") as build,
    ):
        with pytest.raises(RuntimeError, match="1800-second wait expired"):
            macos.ensure("macos-sdk", tmp_path, "owner/repo", HEAD, 23, wait=0)
        build.assert_not_called()


def test_waiting_producers_ignores_other_heads_without_fetching_their_recipe():
    run = {
        "id": 10,
        "head_sha": "c" * 40,
        "status": "in_progress",
        "event": "pull_request",
        "path": trust.WORKFLOW,
        "head_repository": {"full_name": "owner/repo"},
        "pull_requests": [{"number": 23}],
    }
    with (
        patch.object(macos, "api", return_value={"workflow_runs": [run]}) as api,
        patch.object(macos, "fingerprint", return_value=IDENTITY),
        patch.object(macos, "source_fingerprint", return_value=IDENTITY) as source,
        patch.object(macos, "dependency_jobs", return_value=[]),
    ):
        assert macos.waiting_producers("owner/repo", "macos-sdk", HEAD, 23) == []
        assert api.call_count == 5
        assert all(f"head_sha={HEAD}" in call.args[1] for call in api.call_args_list)
        source.assert_not_called()
