"""Closed-path and descriptor mechanics; these fixtures do not qualify a worker."""

import hashlib
import json
from pathlib import Path
from unittest import mock

import pytest

from tools import diagnostic_build_identity as identity
from tools import diagnostic_worker_context as worker

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "name",
    [
        "tools/reference_distribution_config.py",
        "packages/foresight_core/lib/src/search_service.dart",
        "packages/foresight_core/lib/src/credentials.dart",
        "packages/foresight_core/lib/src/service.dart",
        "packages/foresight_core/lib/src/diagnostics/nested/worker.dart",
    ],
)
def test_all_declared_paths_are_classified_before_runtime_content_read(tmp_path, name):
    config = json.loads((ROOT / identity.DEFAULT_CONTRACT).read_text())
    config["worker"]["inputs"].append(name)
    (tmp_path / "tools").mkdir()
    (tmp_path / identity.DEFAULT_CONTRACT).write_text(json.dumps(config))
    original = identity._read

    def read(root, selected, **kwargs):
        assert selected == identity.DEFAULT_CONTRACT, (
            "must classify before source/SDK/package reads"
        )
        return original(root, selected, **kwargs)

    with (
        mock.patch.object(identity, "_read", side_effect=read),
        pytest.raises(identity.IdentityError),
    ):
        worker.collect(
            tmp_path,
            tmp_path / "build",
            tmp_path / "sdk",
            tmp_path / worker.CORE / ".dart_tool/package_config.json",
            "jit",
        )


def test_regular_input_hash_uses_actual_bytes(tmp_path):
    (tmp_path / "code.dart").write_bytes(b"public fixture")
    (tmp_path / "code.dart").chmod(0o644)
    assert (
        worker.digest_file(tmp_path, "code.dart")
        == hashlib.sha256(b"public fixture").hexdigest()
    )


@pytest.mark.parametrize(
    "unsafe", ["file_link", "ancestor_link", "fifo", "group_writable", "hardlink"]
)
def test_unsafe_inputs_refuse_before_any_content_read(tmp_path, unsafe):
    root = tmp_path / "source"
    root.mkdir()
    path = root / "code.dart"
    if unsafe == "file_link":
        path.symlink_to(tmp_path / "absent")
    elif unsafe == "ancestor_link":
        linked = tmp_path / "linked"
        linked.symlink_to(root, target_is_directory=True)
        root = linked
    elif unsafe == "fifo":
        import os

        os.mkfifo(path)
    else:
        path.write_text("public fixture")
        path.chmod(0o644)
        if unsafe == "group_writable":
            path.chmod(0o666)
        else:
            (root / "other.dart").hardlink_to(path)
    with (
        mock.patch.object(
            worker.os, "read", side_effect=AssertionError("unsafe content read")
        ),
        pytest.raises((OSError, identity.IdentityError)),
    ):
        worker.digest_file(root, "code.dart")


def test_selected_package_root_cannot_redirect_into_an_excluded_tree(tmp_path):
    config = tmp_path / worker.CORE / ".dart_tool/package_config.json"
    config.parent.mkdir(parents=True)
    config.write_text(
        json.dumps(
            {
                "configVersion": 2,
                "packages": [
                    {
                        "name": "ffi",
                        "packageUri": "lib/",
                        "languageVersion": "3.3",
                        "rootUri": (
                            tmp_path / "reference_distribution/hosted/pub.dev/ffi-2.1.4"
                        ).as_uri(),
                    }
                ],
            }
        )
    )
    with pytest.raises(identity.IdentityError, match="excluded_worker_package_root"):
        worker.package_roots(config, tmp_path)


@pytest.mark.parametrize(
    "name",
    [
        "../secret",
        "lib/../../private.dart",
        "credentials/key.dart",
        "bin/private",
        "/tmp/file",
    ],
)
def test_external_package_inventory_is_positive(name):
    with pytest.raises(identity.IdentityError):
        worker.external_path(name)


@pytest.fixture
def complete_candidate(tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    config = json.loads((ROOT / identity.DEFAULT_CONTRACT).read_text())
    files = list(worker.EXACT)
    files.extend(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / worker.DIAGNOSTICS).glob("*.dart")
    )
    config["worker"]["inputs"] = sorted(files)
    for name in files:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((ROOT / name).read_bytes())
        path.chmod(0o644)
    contract = root / identity.DEFAULT_CONTRACT
    contract.parent.mkdir()
    contract.write_text(json.dumps(config))
    sdk = tmp_path / "flutter/bin/cache/dart-sdk"
    for name, data in {
        "version": b"3.9.2\n",
        "revision": b"a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd\n",
        "bin/dart": b"synthetic SDK compiler, not an executable qualification",
        "bin/snapshots/kernel-service.dart.snapshot": b"synthetic frontend",
        "lib/core/core.dart": b"library dart.core;\n",
    }.items():
        path = sdk / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o644)
    entries = [
        {
            "name": "foresight_core",
            "rootUri": (root / worker.CORE).as_uri(),
            "packageUri": "lib/",
            "languageVersion": "3.8",
        }
    ]
    for name in sorted(worker.PACKAGES):
        path = tmp_path / "pub-cache/hosted/pub.dev" / f"{name}-1.0.0"
        (path / "lib").mkdir(parents=True)
        (path / "pubspec.yaml").write_text(f"name: {name}\nversion: 1.0.0\n")
        (path / f"lib/{name}.dart").write_text("void publicFixture() {}\n")
        entries.append(
            {
                "name": name,
                "rootUri": path.as_uri(),
                "packageUri": "lib/",
                "languageVersion": "3.3",
            }
        )
    package_config = root / worker.CORE / ".dart_tool/package_config.json"
    package_config.parent.mkdir()
    package_config.write_text(json.dumps({"configVersion": 2, "packages": entries}))
    return root, root / "build", sdk, package_config


def test_candidate_collects_same_scoped_bytes_without_promoting_pending_worker(
    complete_candidate,
):
    # Deliberately synthetic SDK/packages/native receipt. This verifies manifest
    # mechanics, never real SDK, compiler or persistent-sink acceptance.
    with mock.patch.object(
        worker.products, "verify", return_value={"native_id": "a" * 64}
    ):
        first = worker.collect(*complete_candidate, "jit")
        assert worker.collect(*complete_candidate, "jit") == first
    assert first["kind"] == "standalone-worker"
    assert set(first["record"]["packages"]) == worker.PACKAGES
    assert first["worker_id"] == identity._digest(first["record"])
    assert first["record"]["sdk"]["runtime_inputs"]["bin/dart"]
    with pytest.raises(identity.IdentityError, match="worker_closure_not_reviewed"):
        identity.Contract(complete_candidate[0]).worker_identity("a" * 64, "jit")


def test_package_import_cannot_escape_into_application_or_excluded_source(
    complete_candidate,
):
    root, build, sdk, config = complete_candidate
    package = json.loads(config.read_text())["packages"][1]
    path = (
        Path(package["rootUri"].removeprefix("file://"))
        / "lib/"
        / f"{package['name']}.dart"
    )
    path.write_text("import 'package:foresight_core/src/search_service.dart';\n")
    with (
        mock.patch.object(
            worker.products, "verify", return_value={"native_id": "a" * 64}
        ),
        pytest.raises(identity.IdentityError, match="excluded_worker_package_import"),
    ):
        worker.collect(root, build, sdk, config, "jit")
