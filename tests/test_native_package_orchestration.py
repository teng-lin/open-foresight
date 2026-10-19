"""Build native package metadata from fixture payloads at package-manager boundary."""

import json
from pathlib import Path
import subprocess
import sys

import pytest
import test_linux_packages as package_fixtures

packages = package_fixtures.packages


@pytest.fixture
def bundle_fixture():
    case = package_fixtures.LinuxPackagesTest()
    case.setUp()
    try:
        yield case
    finally:
        case.doCleanups()


@pytest.mark.parametrize("kind", ["tar", "deb", "rpm", "arch"])
def test_native_package_cli_binds_actual_output_hash_and_preview_identity(
    bundle_fixture, monkeypatch, kind
):
    case = bundle_fixture
    output = case.root / "packages"
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1234")
    seen = []

    def run(command, **kwargs):
        seen.append(command)
        if command[0] == "dpkg-deb":
            root = Path(command[-2])
            control = (root / "DEBIAN/control").read_text()
            assert "Architecture: amd64" in control
            assert "Version: 1.2.3~nightly.20261019.42-1" in control
            assert (root / "DEBIAN/preinst").stat().st_mode & 0o777 == 0o755
            Path(command[-1]).write_bytes(b"fixture deb")
        elif command[0] == "rpmbuild":
            top = Path(command[command.index("--define") + 1].removeprefix("_topdir "))
            assert "AutoReqProv: no" in Path(command[-1]).read_text()
            (top / "RPMS/fixture.rpm").write_bytes(b"fixture rpm")
        elif command[0] == "makepkg":
            directory = kwargs["cwd"]
            recipe = (directory / "PKGBUILD").read_text()
            assert "pkgver=1.2.3\npkgrel=0.42" in recipe
            assert packages.digest(directory / "payload.tar.gz") in recipe
            (directory / "fixture.pkg.tar.zst").write_bytes(b"fixture arch")
        else:
            assert command[1].endswith("check_abi.py")
            assert command[command.index("--max-glibc") + 1] == "2.39"
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(packages.subprocess, "run", run)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "package",
            "--bundle",
            str(case.bundle),
            "--format",
            kind,
            "--version",
            "1.2.3~nightly.20261019.42",
            "--output",
            str(output),
        ],
    )
    packages.main()
    metadata = list(output.glob("*.build.json"))
    assert len(metadata) == 1
    record = json.loads(metadata[0].read_text())
    installer = Path(str(metadata[0]).removesuffix(".build.json"))
    assert record["sha256"] == packages.digest(installer)
    assert record["revision"] == "a" * 40
    assert record["source_date_epoch"] == 1234
    assert record["native_release"] == ("0.42" if kind == "arch" else "1")
    assert record["format"] == kind
    assert (
        Path(str(installer) + ".sha256").read_text()
        == f"{record['sha256']}  {installer.name}\n"
    )
    if kind == "arch":
        assert (output / "arch-recipe/PKGBUILD").is_file()
        assert (output / "arch-recipe/open-foresight.install").is_file()
    with pytest.raises(FileExistsError):
        packages.main()
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "package",
            "--bundle",
            str(case.bundle),
            "--format",
            kind,
            "--version",
            "invalid",
        ],
    )
    with pytest.raises(SystemExit, match="2"):
        packages.main()


@pytest.mark.parametrize(
    "kind,count", [("rpm", 0), ("rpm", 2), ("arch", 0), ("arch", 2)]
)
def test_package_manager_ambiguous_or_missing_output_is_failure(
    bundle_fixture, monkeypatch, kind, count
):
    case = bundle_fixture
    root, output = case.root / "stage", case.root / "package"
    packages.stage(case.bundle, root)

    def run(command, **kwargs):
        directory = (
            Path(command[command.index("--define") + 1].removeprefix("_topdir "))
            / "RPMS"
            if kind == "rpm"
            else kwargs["cwd"]
        )
        for index in range(count):
            (
                directory / (str(index) + (".rpm" if kind == "rpm" else ".pkg.tar.zst"))
            ).write_bytes(b"fixture")

    monkeypatch.setattr(packages.subprocess, "run", run)
    with pytest.raises(RuntimeError, match="exactly one"):
        (packages.make_rpm if kind == "rpm" else packages.make_arch)(
            root, output, "1.2.3", "1", packages.METADATA, 1234
        )
    assert not output.exists()


@pytest.mark.parametrize(
    "bad", ["absolute", "traversal", "duplicate", "elf", "launcher"]
)
def test_package_validation_rejects_unsafe_inventory_and_unlaunchable_bundle(
    bundle_fixture, bad
):
    case = bundle_fixture
    manifest = case.bundle / "manifest.json"
    data = json.loads(manifest.read_text())
    if bad in ("absolute", "traversal"):
        data["files"][0]["path"] = "/absolute" if bad == "absolute" else "../escape"
    elif bad == "duplicate":
        data["files"].append(data["files"][0])
    elif bad == "elf":
        (case.bundle / "bin/ForesightHelper").write_bytes(b"not x86-64")
        case.manifest()
        data = json.loads(manifest.read_text())
    else:
        (case.bundle / "open-foresight").chmod(0o644)
    manifest.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        packages.validate(case.bundle)
