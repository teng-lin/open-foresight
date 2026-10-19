"""Partial release recovery keeps original source/build identities and bytes."""

import json
import sys

import pytest
from tools import preview_reuse as reuse
from test_preview_reuse import transport, installer_members, REPO, SHA


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def ci_context(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)


@pytest.mark.parametrize("failure", ["missing", "duplicate", "existing"])
def test_installer_recovery_rejects_ambiguous_archive_or_overwrite(
    tmp_path, monkeypatch, failure
):
    members = installer_members()
    if failure == "missing":
        members = {}
    elif failure == "duplicate":
        members["duplicate.deb"] = b"other installer"
    transport(
        monkeypatch, members, ["preview-installer-linux-deb"], ["linux (deb, ubuntu)"]
    )
    destination = tmp_path / "restored"
    if failure == "existing":
        destination.mkdir()
        (destination / "installer.deb").write_bytes(b"keep successful installer")
    with pytest.raises(ValueError):
        reuse.restore(REPO, 42, SHA, "deb", destination)
    if failure == "existing":
        assert (
            destination / "installer.deb"
        ).read_bytes() == b"keep successful installer"


@pytest.mark.parametrize(
    "failure", ["source", "missing", "job", "traversal", "ambiguous", "revision"]
)
def test_application_recovery_rejects_unqualified_or_unbound_source(
    tmp_path, monkeypatch, failure
):
    members = {"app.build.json": json.dumps({"revision": SHA})}
    if failure == "traversal":
        members["../escape"] = b"untrusted"
    elif failure == "ambiguous":
        members["other.build.json"] = json.dumps({"revision": SHA})
    elif failure == "revision":
        members["app.build.json"] = json.dumps({"revision": "b" * 40})
    run, items, jobs, _ = transport(
        monkeypatch, members, ["preview-linux-portable"], ["build / linux-bundle"]
    )
    if failure == "source":
        run["head_sha"] = "b" * 40
    elif failure == "missing":
        items.clear()
    elif failure == "job":
        jobs[0]["conclusion"] = "failure"
    with pytest.raises(ValueError):
        reuse.restore_application(REPO, 42, SHA, "linux", tmp_path / "restored")
    assert not (tmp_path / "escape").exists()


@pytest.mark.parametrize("mode", ["application", "optional", "required", "success"])
def test_recovery_cli_has_distinct_missing_result_and_no_new_build(
    tmp_path, monkeypatch, mode
):
    calls = []
    monkeypatch.setattr(reuse, "restore_application", lambda *a: calls.append(a))
    monkeypatch.setattr(reuse, "restore", lambda *a: {} if mode == "success" else None)
    args = ["recover", "--run", "42", "--source", SHA, "--directory", str(tmp_path)]
    if mode == "application":
        args += ["--application", "linux"]
    elif mode == "optional":
        args += ["--optional"]
    monkeypatch.setattr(sys, "argv", args)
    if mode in ("optional", "required"):
        with pytest.raises((SystemExit, ValueError)) as error:
            reuse.main()
        if mode == "optional":
            assert error.value.code == 4
    else:
        reuse.main()
        assert bool(calls) == (mode == "application")
    assert not list(tmp_path.iterdir())
