"""Preview identity, sequence races, installer provenance and workflow boundaries."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
from unittest.mock import patch

import pytest

from tools import app_version, build_sequence, ci_artifacts, preview_packages as preview
from tools import verify_preview_cloud as cloud
from test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
LABEL = "nightly.20261018.12"

spec = importlib.util.spec_from_file_location(
    "preview_native_package", ROOT / "packaging/package_linux.py"
)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


@pytest.mark.parametrize(
    "source,latest,expected",
    [
        ("0.1.1", "v0.1.1", "0.1.2"),
        ("0.1.2", "v0.1.1", "0.1.2"),
        ("0.1.1", "v0.2.0", "0.2.1"),
        ("0.1.1", None, "0.1.1"),
    ],
)
def test_preview_targets_the_next_unreleased_version(source, latest, expected):
    assert preview.preview_version(source, latest) == expected


@pytest.mark.parametrize(
    "force,validation,build",
    [(False, "standard", False), (True, "standard", True), (False, "full", False)],
)
def test_success_watermark_and_force_full_semantics(force, validation, build):
    def request(repo, route, **kwargs):
        if route == "commits/main":
            return {"sha": SHA}
        if route.startswith("actions/"):
            return {"workflow_runs": [{"id": 1, "head_sha": SHA}]}
        if route == "releases/latest":
            return {"tag_name": "v0.1.1"}
        raise AssertionError(route)

    with (
        patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main", "GITHUB_RUN_ID": "2"}),
        patch.object(
            preview,
            "previous_nightly",
            return_value=None if build else {"summary": "green"},
        ),
        patch.object(preview, "request", side_effect=request),
        patch.object(preview.subprocess, "check_output", return_value=SHA),
        patch.object(preview, "stale", return_value=[]),
        patch.object(preview, "read_version", return_value=("0.1.1", 2)),
        patch.object(preview, "allocate", return_value=12) as allocate,
    ):
        result = preview.plan(
            "owner/repo",
            force,
            validation,
            "intentional distribution configuration rotation" if force else "",
        )
    assert result["build"] == str(build).lower()
    assert allocate.call_count == int(build)
    if build:
        assert result["source"] == SHA and result["build_number"] == "12"
        assert result["package_version"].startswith("0.1.2~nightly.")


def test_planner_rejects_branch_or_advancing_main_before_allocation():
    for ref, remote in (("refs/heads/topic", SHA), ("refs/heads/main", "b" * 40)):
        with (
            patch.dict(os.environ, {"GITHUB_REF": ref}),
            patch.object(preview, "request", return_value={"sha": remote}),
            patch.object(preview.subprocess, "check_output", return_value=SHA),
            patch.object(preview, "allocate") as allocate,
        ):
            with pytest.raises(ValueError):
                preview.plan("owner/repo", True, "standard", "fixture replacement")
            allocate.assert_not_called()


def test_stamping_updates_every_copy_before_compilation(tmp_path):
    for file in (
        app_version.PUBSPEC,
        app_version.CORE_PUBSPEC,
        app_version.DESKTOP_LOCK,
        app_version.DART_VERSION,
    ):
        destination = tmp_path / file
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / file, destination)
    number = app_version.read_version(tmp_path)[1] + 10
    label = f"nightly.20261018.{number}"
    preview.stamp("0.1.2", number, label, SHA, tmp_path)
    assert app_version.read_version(tmp_path) == ("0.1.2", number)
    assert app_version.stale(tmp_path) == []
    assert label in (tmp_path / app_version.DART_VERSION).read_text()
    assert json.loads((tmp_path / preview.IDENTITY).read_text())["source_commit"] == SHA
    with pytest.raises(ValueError):
        preview.stamp("0.1.2", number - 1, label, SHA, tmp_path)
    assert app_version.read_version(tmp_path) == ("0.1.2", number)


def test_sequence_retries_cas_conflicts_and_reads_immutable_state():
    parents = iter(("old", "new"))
    numbers = []
    attempts = []

    def request(repo, route, method="GET", payload=None, **kwargs):
        if route == "git/ref/heads/ci/build-sequence":
            return {"object": {"sha": next(parents)}}
        if route.startswith("contents/"):
            previous = 10 if route.endswith("old") else 11
            return {
                "content": base64.b64encode(
                    json.dumps({"build": previous}).encode()
                ).decode()
            }
        if route == "git/blobs":
            numbers.append(json.loads(payload["content"])["build"])
            return {"sha": "blob"}
        if route == "git/trees":
            return {"sha": "tree"}
        if route == "git/commits":
            return {"sha": "commit"}
        if route == "git/refs/heads/ci/build-sequence":
            attempts.append(payload)
            if len(attempts) == 1:
                raise RuntimeError("HTTP 422 non-fast-forward")
            return {}
        raise AssertionError(route)

    with (
        patch.object(build_sequence, "request", side_effect=request),
        patch.object(build_sequence.time, "sleep"),
    ):
        assert build_sequence.allocate("owner/repo", 2) == 12
    assert numbers == [11, 12]
    assert all(attempt["force"] is False for attempt in attempts)


def test_sequence_initializes_above_source_floor_and_propagates_permissions():
    payloads = []

    def request(repo, route, method="GET", payload=None, **kwargs):
        payloads.append((route, payload))
        if route == "git/ref/heads/ci/build-sequence":
            return None
        return {"sha": "object"}

    with patch.object(build_sequence, "request", side_effect=request):
        assert build_sequence.allocate("owner/repo", 100) == 101
    assert json.loads(payloads[1][1]["content"])["build"] == 101
    assert payloads[-1][1]["ref"] == "refs/heads/ci/build-sequence"
    with patch.object(build_sequence, "request", side_effect=RuntimeError("HTTP 403")):
        with pytest.raises(RuntimeError, match="403"):
            build_sequence.allocate("owner/repo", 2)


@pytest.mark.parametrize(
    "kind,expected",
    [
        ("deb", ("0.1.2~" + LABEL, "1")),
        ("rpm", ("0.1.2~" + LABEL, "1")),
        ("arch", ("0.1.2", "0.12")),
    ],
)
def test_native_preview_versions_preserve_stable_upgrade_order(kind, expected):
    assert package.native_version("0.1.2~" + LABEL, "1", kind) == expected
    assert package.native_version("0.1.2", "1", kind) == ("0.1.2", "1")
    for invalid in ("0.1.2-nightly", "0.1.2~nightly.20261018.0", "0.1.2;false"):
        with pytest.raises(ValueError):
            package.native_version(invalid, "1", kind)


def installers(root):
    for kind, suffix in preview.EXTENSIONS.items():
        directory = root / kind
        directory.mkdir()
        file = directory / ("installer" + suffix)
        file.write_bytes(kind.encode())
        checksum = hashlib.sha256(file.read_bytes()).hexdigest()
        Path(str(file) + ".sha256").write_text(f"{checksum}  {file.name}\n")
        Path(str(file) + ".build.json").write_text(
            json.dumps(
                {
                    "revision": SHA,
                    "version": "0.1.2" if kind == "dmg" else "0.1.2~" + LABEL,
                    "build_number": 12,
                    "sha256": checksum,
                    "format": kind,
                    "arch": "arm64" if kind == "dmg" else "x86_64",
                }
            )
        )


def test_final_manifest_requires_all_formats_same_source_and_build(tmp_path):
    installers(tmp_path)
    result = preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "standard")
    assert len(result["installers"]) == 5
    assert result["full_model_cloud_acceptance"] == "not_run"
    with pytest.raises(ValueError, match="build numbers"):
        preview.manifest(tmp_path, "0.1.2", 13, LABEL, SHA, "full")
    (tmp_path / "deb/installer.deb").write_bytes(b"changed")
    with pytest.raises(ValueError):
        preview.receipt(tmp_path / "deb", "deb", SHA)


def test_missing_formats_and_foreign_source_cannot_be_published(tmp_path):
    installers(tmp_path)
    with pytest.raises(ValueError, match="pinned source"):
        preview.receipt(tmp_path / "dmg", "dmg", "b" * 40)
    (tmp_path / "rpm/installer.rpm").unlink()
    with pytest.raises(ValueError, match="Missing"):
        preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "full")


def test_cloud_acceptance_reads_only_bundled_values(tmp_path):
    launcher = tmp_path / "open-foresight"
    launcher.write_text(
        "export FORESIGHT_SEARCH_API_KEY='bundled search'\nexport FORESIGHT_WEB_CONTENT_API_KEY=bundled-web\nexec desktop\n"
    )
    assert cloud.configuration(tmp_path) == {
        "FORESIGHT_SEARCH_API_KEY": "bundled search",
        "FORESIGHT_WEB_CONTENT_API_KEY": "bundled-web",
    }
    launcher.write_text("exec desktop\n")
    with pytest.raises(ValueError, match="bundled distribution"):
        cloud.configuration(tmp_path)


def test_preview_workflow_has_no_release_publication_and_gates_downloads():
    workflow = parse_workflow(
        (ROOT / ".github/workflows/preview-packages.yml").read_text()
    )
    assert "schedule" in workflow["on"] and "workflow_dispatch" in workflow["on"]
    assert "pull_request" not in workflow["on"]
    assert set(workflow["jobs"]["publish"]["needs"]) == {
        "plan",
        "build",
        "linux",
        "macos",
    }
    assert workflow["jobs"]["build"]["uses"] == "./.github/workflows/macos.yml"
    assert workflow["jobs"]["build"]["with"]["preview"] is True
    assert "gh release" not in json.dumps(workflow)
    official = parse_workflow((ROOT / ".github/workflows/release.yml").read_text())
    assert official["concurrency"]["group"] == "distribution-packages"
    assert "preview-packages-exercise" in workflow["concurrency"]["group"]
    assert "inputs.exercise_failure_path" in workflow["concurrency"]["group"]
    assert all(
        "concurrency" not in official["jobs"][name] for name in ("prepare", "publish")
    )
    builds = parse_workflow((ROOT / ".github/workflows/macos.yml").read_text())
    assert builds["jobs"]["distribution-number"]["permissions"]["contents"] == "write"
    assert (
        "github.ref == 'refs/heads/main'" in builds["jobs"]["distribution-number"]["if"]
    )
    for name in ("macos", "linux-bundle"):
        steps = builds["jobs"][name]["steps"]
        if name == "macos":
            setup = next(
                step
                for step in steps
                if step.get("uses") == "./.github/actions/setup-macos-stage"
            )
            assert (
                setup["with"]["build-number"]
                == "${{ inputs.build_number || needs.distribution-number.outputs.build_number }}"
            )
            composite = parse_workflow(
                (ROOT / ".github/actions/setup-macos-stage/action.yml").read_text()
            )
            steps = composite["runs"]["steps"]
        stamp = next(
            step
            for step in steps
            if "tools/preview_packages.py stamp" in step.get("run", "")
        )
        assert "--source" in stamp["run"] and "--build-number" in stamp["run"]


def test_application_receipts_bind_to_the_actual_source_checkout(tmp_path):
    with patch.object(ci_artifacts.subprocess, "check_output", return_value="b" * 40):
        with pytest.raises(ValueError, match="actual built checkout"):
            ci_artifacts.pack("macos-app", SHA, tmp_path, tmp_path / "output")
    (tmp_path / "identity.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": "macos-app",
                "identity": SHA,
                "source_commit": "b" * 40,
            }
        )
    )
    with pytest.raises(ValueError, match="requested source"):
        ci_artifacts.unpack("macos-app", SHA, tmp_path, tmp_path / "destination")


def test_producer_pin_never_falls_back_to_another_successful_run(tmp_path):
    artifact = {
        "expired": False,
        "name": ci_artifacts.name("macos-app", SHA),
        "workflow_run": {"id": 1},
    }
    with patch.object(
        ci_artifacts, "api", return_value={"artifacts": [artifact]}
    ) as api:
        assert not ci_artifacts.pull(
            "owner/repo", "macos-app", SHA, tmp_path / "destination", source_run=2
        )
    assert api.call_count == 1


def test_preview_dmg_receipt_rejects_foreign_build_bytes(tmp_path):
    installers(tmp_path)
    path = tmp_path / "dmg/installer.dmg.build.json"
    metadata = json.loads(path.read_text())
    metadata["sha256"] = "b" * 64
    path.write_text(json.dumps(metadata))
    with pytest.raises(ValueError, match="checksum or format"):
        preview.receipt(tmp_path / "dmg", "dmg", SHA)
