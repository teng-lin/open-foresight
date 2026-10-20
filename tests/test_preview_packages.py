"""Preview identity, sequence races, installer provenance and workflow boundaries."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
from unittest.mock import patch

import pytest

from tools import app_version, build_sequence, ci_artifacts, preview_packages as preview
from tools import verify_preview_cloud as cloud
from test_pull_request_workflows import parse_workflow
from test_ci_release_candidates import (
    producer as producer,
    REPOSITORY as CANDIDATE_REPOSITORY,
    SOURCE as CANDIDATE_SOURCE,
)

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
                    "version": "0.1.2" if kind in ("dmg", "tar") else "0.1.2~" + LABEL,
                    "build_number": 12,
                    "sha256": checksum,
                    "format": kind,
                    "arch": "arm64" if kind == "dmg" else "x86_64",
                }
            )
        )
    portable = root / "tar"
    (portable / "distribution-stamp.json").write_text(
        json.dumps(
            {
                "version": "0.1.2",
                "build_number": 12,
                "label": LABEL,
                "source_commit": SHA,
            }
        )
    )
    # Produce the real payload/identity receipt before the in-run verifier writes
    # its retained original-source qualification beside the extracted bytes.
    with (
        tempfile.TemporaryDirectory() as directory,
        patch.object(ci_artifacts.subprocess, "check_output", return_value=SHA),
        patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
    ):
        output = Path(directory)
        ci_artifacts.pack(
            "linux-app", SHA, portable, output, tier="preview", label=LABEL
        )
        original = json.loads((output / "identity.json").read_text())
    (portable / "source-qualification.json").write_text(
        json.dumps({"source_receipt": original})
    )


def test_final_manifest_requires_all_formats_same_source_and_build(
    tmp_path, monkeypatch
):
    monkeypatch.setenv(
        "GITHUB_STEP_SUMMARY", str(tmp_path.parent / (tmp_path.name + ".summary"))
    )
    installers(tmp_path)
    portable = tmp_path / "tar/installer.tar.gz"
    original_bytes = portable.read_bytes()
    result = preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "standard")
    assert portable.read_bytes() == original_bytes
    assert (
        next(item for item in result["installers"] if item["format"] == "tar")[
            "version"
        ]
        == "0.1.2"
    )
    assert len(result["installers"]) == 5
    assert result["full_model_cloud_acceptance"] == "not_run"
    with pytest.raises(ValueError, match="build numbers"):
        preview.manifest(tmp_path, "0.1.2", 13, LABEL, SHA, "full")
    (tmp_path / "deb/installer.deb").write_bytes(b"changed")
    with pytest.raises(ValueError):
        preview.receipt(tmp_path / "deb", "deb", SHA)


@pytest.mark.parametrize(
    "failure",
    [
        "missing-stamp",
        "missing-receipt",
        "symlink-stamp",
        "wrong-stamp",
        "preview-label",
        "source",
        "tier",
        "distribution",
        "invalid-receipt",
    ],
)
def test_portable_preview_requires_original_stamped_label_and_receipt(
    tmp_path, failure
):
    installers(tmp_path)
    stamp = tmp_path / "tar/distribution-stamp.json"
    qualification = tmp_path / "tar/source-qualification.json"
    if failure.startswith("missing-"):
        (stamp if failure == "missing-stamp" else qualification).unlink()
    elif failure == "symlink-stamp":
        original = stamp.read_text()
        stamp.unlink()
        target = tmp_path / "stamp.json"
        target.write_text(original)
        stamp.symlink_to(target)
    elif failure == "wrong-stamp":
        stamp.write_text("{}")
    else:
        value = json.loads(qualification.read_text())
        original = value["source_receipt"]
        if failure == "preview-label":
            original["label"] = "nightly.20261019.99"
        elif failure == "source":
            original["source_commit"] = "b" * 40
        elif failure == "tier":
            original["tier"] = "release"
        elif failure == "distribution":
            original["distribution"]["build_number"] = 13
        else:
            original["sha256"] = "invalid"
        qualification.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="Portable preview"):
        preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "standard")


def test_missing_formats_and_foreign_source_cannot_be_published(tmp_path, monkeypatch):
    monkeypatch.setenv(
        "GITHUB_STEP_SUMMARY", str(tmp_path.parent / (tmp_path.name + ".summary"))
    )
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
    for name in ("macos", "linux-build"):
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


def test_producer_pin_never_falls_back_to_another_successful_run(producer, tmp_path):
    payload = producer.item(ci_artifacts.name("macos-app", CANDIDATE_SOURCE))
    payload["workflow_run"]["id"] = 1
    producer.downloads.clear()
    with pytest.raises(ValueError, match="original upload"):
        ci_artifacts.pull(
            CANDIDATE_REPOSITORY,
            "macos-app",
            CANDIDATE_SOURCE,
            tmp_path / "destination",
            source_run=42,
            consumer="release-preparation",
        )
    assert payload["id"] not in producer.downloads
    assert not (tmp_path / "destination").exists()


def test_preview_dmg_receipt_rejects_foreign_build_bytes(tmp_path):
    installers(tmp_path)
    path = tmp_path / "dmg/installer.dmg.build.json"
    metadata = json.loads(path.read_text())
    metadata["sha256"] = "b" * 64
    path.write_text(json.dumps(metadata))
    with pytest.raises(ValueError, match="checksum or format"):
        preview.receipt(tmp_path / "dmg", "dmg", SHA)


@pytest.fixture
def workflow_installer_tree(tmp_path, monkeypatch):
    # Keep fixture provenance and summaries separate from inherited hosted CI.
    monkeypatch.setenv("GITHUB_REPOSITORY", "fixture/preview")
    monkeypatch.setenv("GITHUB_RUN_ID", "41")
    monkeypatch.setenv(
        "GITHUB_STEP_SUMMARY", str(tmp_path.parent / (tmp_path.name + "-summary.md"))
    )
    # Match download-artifact's non-merged preview-installer-* directories and
    # the separately downloaded canonical portable bundle.
    installers(tmp_path)
    names = {
        "deb": "preview-installer-linux-deb",
        "rpm": "preview-installer-linux-rpm",
        "arch": "preview-installer-linux-arch",
        "dmg": "preview-installer-macos",
        "tar": "portable",
    }
    for kind, name in names.items():
        (tmp_path / kind).rename(tmp_path / name)
    staged = tmp_path.parent / (tmp_path.name + "-arch-stage")
    staged.mkdir()
    (staged / "application").write_bytes(b"actual retained package input")
    output = tmp_path / names["arch"] / "installer.pkg.tar.zst"

    def makepkg(command, *, cwd, check, timeout):
        assert command == ["makepkg", "--nodeps", "--noconfirm"]
        assert check is True and timeout == 300
        (Path(cwd) / "fixture.pkg.tar.zst").write_bytes(b"Arch installer fixture")

    # Execute make_arch's real archive/recipe retention. Only the external Arch
    # tool is substituted, keeping this filesystem contract portable on macOS.
    with monkeypatch.context() as context:
        context.setattr(package.subprocess, "run", makepkg)
        package.make_arch(staged, output, "0.1.2", "0.12", package.METADATA, 1234)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    Path(str(output) + ".sha256").write_text(f"{digest}  {output.name}\n")
    metadata = Path(str(output) + ".build.json")
    record = json.loads(metadata.read_text())
    metadata.write_text(json.dumps({**record, "sha256": digest}))
    recipe = output.parent / "arch-recipe"
    retained = recipe / "payload.tar.gz"
    with tarfile.open(retained) as archive:
        assert archive.extractfile("payload/application").read() == (
            b"actual retained package input"
        )
    assert (
        hashlib.sha256(retained.read_bytes()).hexdigest()
        in (recipe / "PKGBUILD").read_text()
    )
    return tmp_path


def test_workflow_manifest_preserves_retained_arch_input_without_counting_it_as_installer(
    workflow_installer_tree,
):
    root = workflow_installer_tree
    retained = root / "preview-installer-linux-arch/arch-recipe/payload.tar.gz"
    before = retained.read_bytes()
    result = preview.manifest(root, "0.1.2", 12, LABEL, SHA, "standard")
    assert len(result["installers"]) == 5
    assert result["run_url"] == "https://github.com/fixture/preview/actions/runs/41"
    portable = next(item for item in result["installers"] if item["format"] == "tar")
    assert portable["asset"] == "installer.tar.gz"
    checksum = next(
        item
        for item in result["files"]
        if item["path"] == retained.relative_to(root).as_posix()
    )
    assert checksum["sha256"] == hashlib.sha256(before).hexdigest()
    assert retained.read_bytes() == before


@pytest.mark.parametrize(
    "change", ["checksum", "source", "format", "version", "build-number"]
)
def test_retained_arch_input_does_not_weaken_installer_provenance(
    workflow_installer_tree, change
):
    root = workflow_installer_tree
    portable = root / "portable/installer.tar.gz"
    if change == "checksum":
        portable.write_bytes(b"changed installer bytes")
    else:
        metadata = Path(str(portable) + ".build.json")
        record = json.loads(metadata.read_text())
        field, value = {
            "source": ("revision", "b" * 40),
            "format": ("format", "arch"),
            "version": ("version", "9.9.9~" + LABEL),
            "build-number": ("build_number", 13),
        }[change]
        metadata.write_text(json.dumps({**record, field: value}))
    message = {
        "checksum": "checksum",
        "source": "pinned source",
        "format": "checksum or format",
        "version": "preview identity",
        "build-number": "build numbers",
    }[change]
    with pytest.raises(ValueError, match=message):
        preview.manifest(root, "0.1.2", 12, LABEL, SHA, "standard")
    assert not (root / "preview.json").exists()


@pytest.mark.parametrize(
    "duplicate",
    [
        "surprise.tar.gz",
        "preview-installer-linux-arch/arch-recipe/another.tar.gz",
        "unrelated/arch-recipe/payload.tar.gz",
        "preview-installer-linux-arch/arch-recipe/nested/payload.tar.gz",
    ],
)
def test_manifest_still_rejects_unexpected_duplicate_tar_archives(
    workflow_installer_tree, duplicate
):
    path = workflow_installer_tree / duplicate
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"unexpected duplicate archive")
    with pytest.raises(ValueError, match="Missing or duplicate preview installer: tar"):
        preview.manifest(workflow_installer_tree, "0.1.2", 12, LABEL, SHA, "standard")


def test_retained_arch_input_cannot_replace_missing_portable_installer(
    workflow_installer_tree,
):
    (workflow_installer_tree / "portable/installer.tar.gz").unlink()
    with pytest.raises(ValueError, match="Missing or duplicate preview installer: tar"):
        preview.manifest(workflow_installer_tree, "0.1.2", 12, LABEL, SHA, "standard")


def test_retained_input_exception_requires_one_unambiguous_arch_installer(
    workflow_installer_tree,
):
    (workflow_installer_tree / "duplicate.pkg.tar.zst").write_bytes(b"duplicate")
    with pytest.raises(
        ValueError, match="Missing or duplicate preview installer: arch"
    ):
        preview.manifest(workflow_installer_tree, "0.1.2", 12, LABEL, SHA, "standard")
