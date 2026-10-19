"""Recovery keeps archive integrity and release authorization independent."""

import hashlib
import io
import json
import tarfile
import zipfile

import pytest

from tools import macos_bundle as bundle
from tools import publish_linux_package_aliases as aliases
from tools import reuse_release_acceptance as acceptance
from test_publish_linux_package_aliases import published as published
from test_publish_linux_package_aliases import resolve
from test_release_acceptance_report import evidence
from test_reuse_release_acceptance import fixture as acceptance_fixture
from test_sdk_final_approval import Evidence, run


@pytest.mark.parametrize("number", [None, True, -1, "119"])
def test_invalid_pr_references_cannot_approve_original_sdk(number):
    proof = Evidence()
    candidate = run()
    candidate["pull_requests"] = [{"number": number}]
    assert not proof.qualify(candidate)
    assert proof.calls == []


def test_sdk_final_approval_cannot_authorize_application_artifacts():
    proof = Evidence()
    assert not proof.qualify(component="macos-app")
    assert proof.calls == []


@pytest.mark.parametrize("failure", ["missing", "directory", "oversized", "scalar"])
def test_registry_descriptor_requires_bounded_regular_object_metadata(
    published, failure
):
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w:gz") as archive:
        metadata = tarfile.TarInfo(
            "payload/other.json" if failure == "missing" else "payload/image.json"
        )
        raw = b"[]" if failure == "scalar" else b"{}"
        if failure == "directory":
            metadata.type = tarfile.DIRTYPE
        else:
            if failure == "oversized":
                raw = b" " * 65537
            metadata.size = len(raw)
        archive.addfile(metadata, io.BytesIO(raw))
    published["payload"] = payload.getvalue()
    published["receipt"]["sha256"] = hashlib.sha256(payload.getvalue()).hexdigest()
    published["seal"]()
    with pytest.raises(ValueError, match="registry descriptor metadata"):
        resolve(published)
    assert published["downloaded"] == [20]


def test_descriptor_pagination_cannot_loop_over_repeated_artifacts(
    published, monkeypatch
):
    artifact = dict(published["artifact"], expired=True)
    monkeypatch.setattr(
        aliases.artifacts, "api", lambda *a: {"artifacts": [artifact] * 100}
    )
    with pytest.raises(RuntimeError, match="Repeated descriptor page"):
        resolve(published)
    assert published["downloaded"] == []


def test_descriptor_zip_member_limit_is_independent_of_transfer_metadata(published):
    raw = io.BytesIO()
    with zipfile.ZipFile(raw, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("identity.json", b" " * (aliases.MAX_DESCRIPTOR_BYTES + 1))
        archive.writestr("payload.tar.gz", published["payload"])
    published["blobs"][20] = raw.getvalue()
    published["artifact"]["digest"] = (
        "sha256:" + hashlib.sha256(raw.getvalue()).hexdigest()
    )
    with pytest.raises(ValueError, match="Oversized registry descriptor member"):
        resolve(published)


@pytest.mark.parametrize("changed_bytes", [False, True])
def test_manual_evidence_reuse_still_binds_exact_accepted_installer_bytes(
    monkeypatch, changed_bytes
):
    acceptance_fixture(monkeypatch)
    records = evidence()
    if changed_bytes:
        records[0]["installer_sha256"] = "f" * 64
        with pytest.raises(ValueError):
            acceptance.restore("owner/repo", "v0.1.2", 42, json.dumps(records))
    else:
        result = acceptance.restore("owner/repo", "v0.1.2", 42, json.dumps(records))
        assert result["status"] == "passed"
        assert result["gpu_inference"]["status"] == "manual_passed"
        assert result["reused_validation_from"]["artifact"] == 5


def test_rpath_without_executable_context_skips_unresolvable_search_root(
    tmp_path, monkeypatch
):
    app = tmp_path / "App.app"
    owner = app / "Contents/Resources/lib/plugin.dylib"
    owner.parent.mkdir(parents=True)
    library = owner.with_name("dependency.dylib")
    library.write_bytes(b"verified library")
    monkeypatch.setattr(bundle, "rpaths", lambda path: ["@executable_path/../lib"])
    monkeypatch.setattr(bundle, "shared_cache_library", lambda path: False)
    with pytest.raises(ValueError, match="Unresolved dependency"):
        bundle.resolve_dependency("@rpath/dependency.dylib", owner, app)
    assert (
        bundle.resolve_dependency(
            "@rpath/dependency.dylib", owner, app, inherited_rpaths=["@loader_path"]
        )
        == library.resolve()
    )


def test_actual_shared_cache_match_can_resolve_cache_only_rpath_library(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(bundle, "rpaths", lambda path: ["/usr/lib/swift"])
    monkeypatch.setattr(
        bundle,
        "shared_cache_library",
        lambda path: str(path) == "/usr/lib/swift/libswiftCore.dylib",
    )
    result = bundle.resolve_dependency(
        "@rpath/libswiftCore.dylib", tmp_path / "owner", tmp_path / "App.app"
    )
    assert str(result) == "/usr/lib/swift/libswiftCore.dylib"
