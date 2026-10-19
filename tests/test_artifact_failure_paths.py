"""Transport and receipt failures cannot discard or silently rebuild SDK bytes."""

import hashlib
import io
import json
import subprocess
import sys
import tarfile
import zipfile
from unittest.mock import Mock

import pytest
from tools import ci_artifacts as artifacts
from test_sdk_approval_bridge import original as original
from test_sdk_approval_bridge import REPOSITORY, SEMANTIC


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def ci_context(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_RUN_ID", "1234")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)


@pytest.mark.parametrize(
    "failure", ["server", "timeout", "forbidden", "missing", "malformed", "exhausted"]
)
def test_metadata_transport_retries_transient_failures_without_bypassing_validation(
    monkeypatch, capsys, failure
):
    calls, delays = [], []
    monkeypatch.setenv("GH_DEBUG", "api")

    def request(command, **kwargs):
        calls.append(command)
        assert "GH_DEBUG" not in kwargs["env"]
        assert kwargs["stderr"] == subprocess.PIPE
        if failure == "malformed":
            return b"not json"
        if len(calls) == 2 and failure in ("server", "timeout"):
            return b'{"jobs":[]}'
        if failure == "timeout":
            raise subprocess.TimeoutExpired(command, 300, stderr=b"request timed out\n")
        status = {"forbidden": 403, "missing": 404}.get(failure, 502)
        raise subprocess.CalledProcessError(
            1,
            command,
            output=json.dumps({"status": status}).encode(),
            stderr=f"gh: Server Error (HTTP {status})\n".encode(),
        )

    monkeypatch.setattr(artifacts.subprocess, "check_output", request)
    monkeypatch.setattr(artifacts.time, "sleep", delays.append)
    if failure in ("server", "timeout"):
        assert artifacts.api(REPOSITORY, "actions/runs/1/jobs") == {"jobs": []}
        assert len(calls) == 2 and delays == [1]
        assert "Retrying" in capsys.readouterr().err
    else:
        with pytest.raises((subprocess.CalledProcessError, ValueError)):
            artifacts.api(REPOSITORY, "actions/runs/1/jobs")
        assert len(calls) == (3 if failure == "exhausted" else 1)
        assert delays == ([1, 2] if failure == "exhausted" else [])


@pytest.mark.parametrize(
    "text",
    [
        "# sdk-recipe: linux-core begin\n# sdk-recipe: linux-sdk begin\n",
        "# sdk-recipe: linux-core begin\n",
        "unmarked\n",
    ],
)
def test_broken_recipe_regions_never_produce_a_compatibility_key(tmp_path, text):
    path = tmp_path / "workflow.yml"
    path.write_text(text)
    with pytest.raises(ValueError):
        artifacts.recipe_regions(path, "linux-core")


def test_source_tree_binds_regular_files_and_rejects_links(tmp_path):
    (tmp_path / "directory").mkdir()
    source = tmp_path / "directory/source.h"
    source.write_bytes(b"header")
    assert artifacts.source_tree(tmp_path) == {
        "directory/source.h": {
            "sha256": hashlib.sha256(b"header").hexdigest(),
            "executable": False,
        }
    }
    (tmp_path / "link").symlink_to(source)
    with pytest.raises(ValueError, match="symlinks"):
        artifacts.source_tree(tmp_path)


@pytest.mark.parametrize(
    "component,identity", [("unknown", "a" * 64), ("linux-core", "main")]
)
def test_invalid_artifact_address_rejected(component, identity):
    with pytest.raises(ValueError, match="identity"):
        artifacts.name(component, identity)


@pytest.mark.parametrize(
    "failure", ["missing", "ambiguous", "revision", "version", "build-number"]
)
def test_application_distribution_requires_unambiguous_source_and_version(
    tmp_path, failure
):
    record = {"revision": "a" * 40, "version": "1.2.3", "build_number": 42}
    if failure == "revision":
        record["revision"] = "b" * 40
    elif failure == "version":
        record["version"] = "nightly"
    elif failure == "build-number":
        record["build_number"] = True
    if failure != "missing":
        (tmp_path / "app.build.json").write_text(json.dumps(record))
    if failure == "ambiguous":
        (tmp_path / "other.build.json").write_text(json.dumps(record))
    with pytest.raises(ValueError):
        artifacts.application_distribution(tmp_path, "linux-app", "a" * 40)


def test_archive_root_mismatch_does_not_create_prefix(tmp_path):
    source = tmp_path / "artifact"
    source.mkdir()
    archive = source / "payload.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        stream.addfile(tarfile.TarInfo("foreign"))
    (source / "identity.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": "linux-core",
                "identity": SEMANTIC,
                "sha256": artifacts.digest(archive),
            }
        )
    )
    destination = tmp_path / "destination"
    with pytest.raises(ValueError, match="archive root"):
        artifacts.unpack("linux-core", SEMANTIC, source, destination)
    assert not destination.exists()


def test_symlinked_qualification_cannot_be_repacked_as_trusted_metadata(
    tmp_path, monkeypatch
):
    prefix = tmp_path / "prefix"
    prefix.mkdir()
    metadata = tmp_path / "outside.json"
    metadata.write_text("{}")
    (prefix / "source-qualification.json").symlink_to(metadata)
    monkeypatch.setattr(artifacts.subprocess, "check_output", lambda *a, **kw: "a" * 40)
    with pytest.raises(ValueError, match="metadata must be regular"):
        artifacts.pack("linux-core", SEMANTIC, prefix, tmp_path / "output")
    assert not (tmp_path / "output/identity.json").exists()


def test_invalid_receipt_cannot_be_published(tmp_path):
    (tmp_path / "identity.json").write_text("{}")
    with pytest.raises(ValueError, match="source artifact receipt"):
        artifacts.publish_receipt(
            REPOSITORY, "linux-core", SEMANTIC, tmp_path, 1, tmp_path / "output"
        )
    assert not (tmp_path / "output").exists()


@pytest.mark.parametrize("body", ["not JSON", "[]"])
def test_optional_api_does_not_swallow_unparseable_transport_errors(monkeypatch, body):
    failure = subprocess.CalledProcessError(1, "gh", output=body)
    monkeypatch.setattr(artifacts, "api", Mock(side_effect=failure))
    with pytest.raises((subprocess.CalledProcessError, AttributeError)):
        artifacts.optional_api(REPOSITORY, "actions/artifacts/1")


def test_job_pagination_keeps_successful_later_page(monkeypatch):
    routes = []

    def api(repo, route):
        routes.append(route)
        return {
            "jobs": [{"name": "unrelated"}] * 100
            if len(routes) == 1
            else [{"name": "Build Linux core", "conclusion": "success"}]
        }

    monkeypatch.setattr(artifacts, "api", api)
    assert len(artifacts.dependency_jobs(REPOSITORY, 99)) == 101
    assert routes[-1].endswith("page=2")
    assert not artifacts.in_producer_attempt({"created_at": "invalid"}, {})


@pytest.mark.parametrize("failure", ["members", "receipt"])
def test_original_payload_still_requires_its_exact_envelope(
    original, monkeypatch, failure
):
    entry = original["entry"]
    payload = original["records"]["actions/artifacts/5"]
    monkeypatch.setattr(artifacts, "approved_original", lambda *a: (entry, payload))
    with zipfile.ZipFile(io.BytesIO(original["payloads"][5])) as source:
        files = {name: source.read(name) for name in source.namelist()}
    if failure == "members":
        files["unexpected"] = b"untrusted"
    else:
        receipt = json.loads(files["identity.json"])
        receipt["source_commit"] = "0" * 40
        files["identity.json"] = json.dumps(receipt).encode()
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    original["payloads"][5] = stream.getvalue()
    payload["digest"] = "sha256:" + hashlib.sha256(stream.getvalue()).hexdigest()
    destination = original["root"] / "invalid"
    with pytest.raises(ValueError, match="original SDK archive|Original SDK receipt"):
        artifacts.pull(REPOSITORY, "linux-core", SEMANTIC, destination)
    assert not destination.exists()


def test_malformed_eligibility_api_aborts_probe_and_pull(original, monkeypatch):
    monkeypatch.setattr(artifacts, "approved_original", lambda *a: None)
    sidecar = original["records"]["actions/artifacts/6"]
    payload = original["records"]["actions/artifacts/5"]
    monkeypatch.setattr(
        artifacts,
        "api",
        lambda repo, route: (
            {"artifacts": [sidecar if "receipt-ci-" in route else payload]}
            if route.startswith("actions/artifacts?")
            else {}
        ),
    )
    monkeypatch.setattr(
        artifacts,
        "eligible_run",
        Mock(side_effect=json.JSONDecodeError("bad API", "", 0)),
    )
    with pytest.raises(json.JSONDecodeError):
        artifacts.probe(
            REPOSITORY,
            "linux-core",
            entry_identity := original["entry"]["legacy_identity"],
        )
    with pytest.raises(json.JSONDecodeError):
        artifacts.pull(
            REPOSITORY, "linux-core", entry_identity, original["root"] / "invalid"
        )
    assert not original["downloads"]


def test_cli_without_output_file_has_no_implicit_side_effects(monkeypatch):
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    monkeypatch.setattr(artifacts, "fingerprint", lambda *a: SEMANTIC)
    monkeypatch.setattr(sys, "argv", ["artifacts", "keys"])
    artifacts.main()
    monkeypatch.setattr(artifacts, "probe", lambda *a: True)
    monkeypatch.setattr(
        sys, "argv", ["artifacts", "probe", "--component", "linux-core"]
    )
    artifacts.main()
