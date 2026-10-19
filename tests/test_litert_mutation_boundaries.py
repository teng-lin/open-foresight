"""Verified wheel receipts remain authoritative at extraction/probe boundaries."""

from types import SimpleNamespace
from unittest.mock import Mock
import zipfile

import pytest
import test_litert_extensions as fixtures

extensions = fixtures.extensions


@pytest.fixture
def wheel():
    case = fixtures.ExtensionArtifactsTest()
    case.setUp()
    try:
        yield case
    finally:
        case.doCleanups()


@pytest.mark.parametrize("failure", ["object", "platform", "name", "incomplete"])
def test_manifest_and_wheel_structure_required_before_install(wheel, failure):
    wheel.fixture()
    platform = "darwin"
    if failure == "object":
        wheel.path.write_text("[]")
    elif failure == "platform":
        platform = "unsupported"
    elif failure == "name":
        library = wheel.root / wheel.manifest["library"]
        library.rename(wheel.root / "other.dylib")
        wheel.manifest["library"] = "other.dylib"
        wheel.save()
    else:
        with zipfile.ZipFile(wheel.root / "api.whl", "w") as archive:
            archive.writestr("unrelated", b"bytes")
        wheel.manifest["wheel_sha256"] = extensions.file_sha256(wheel.root / "api.whl")
        wheel.save()
    with pytest.raises(ValueError):
        extensions.verify_extensions_manifest(wheel.path, platform_name=platform)


def test_authenticated_wheel_can_create_explicit_directories_and_hash_large_vendor(
    wheel,
):
    vendor = extensions.MACOS_VENDOR_LIBRARIES[0]
    path = wheel.fixture(
        extra=[("litert_lm/" + vendor, b"v" * 4096), ("litert_lm/data/", b"")]
    )
    bundle = extensions.verify_extensions_manifest(path, platform_name="darwin")
    source = wheel.root / "source"
    source.mkdir()
    destination = wheel.root / "copy"
    target = destination / "site-packages"
    target.mkdir(parents=True)
    extensions.install_extension_wheel(
        bundle,
        site_packages=target,
        source_prefix=source,
        destination_prefix=destination,
    )
    assert (target / "litert_lm/data").is_dir()
    assert (target / "litert_lm" / vendor).read_bytes() == b"v" * 4096
    assert not list(source.iterdir())


@pytest.mark.parametrize("failure", ["create", "setter"])
def test_native_capability_probe_always_releases_created_config(
    wheel, monkeypatch, failure
):
    wheel.fixture()
    library = wheel.root / "liblitert-lm.dylib"
    create = Mock(return_value=None if failure == "create" else 123)
    delete = Mock()
    setter = Mock(return_value=1)
    monkeypatch.setattr(
        extensions.ctypes,
        "CDLL",
        lambda *a: SimpleNamespace(
            litert_lm_session_config_create=create,
            litert_lm_session_config_delete=delete,
            litert_lm_session_config_add_stop_token_sequence=setter,
        ),
    )
    with pytest.raises(ValueError):
        extensions.probe_native_extensions(library)
    if failure == "create":
        delete.assert_not_called()
        setter.assert_not_called()
    else:
        delete.assert_called_once_with(123)


@pytest.mark.parametrize("platform", ["linux", "darwin"])
@pytest.mark.parametrize(
    "failure", ["platform", "changed-wheel", "missing-vendor", "escape", "checksum"]
)
def test_copy_rechecks_immutable_wheel_and_confines_outputs(
    wheel, monkeypatch, platform, failure
):
    header = (
        wheel.elf(b"native")
        if platform == "linux"
        else b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01native"
    )
    path = wheel.fixture(platform=platform, native=header)
    bundle = extensions.verify_extensions_manifest(path, platform_name=platform)
    target = wheel.root / "lib"
    target.mkdir()
    native = target / bundle.library.name
    native.write_bytes(bundle.library.read_bytes())
    copy = (
        extensions.copy_linux_extension_dependencies
        if platform == "linux"
        else extensions.copy_macos_extension_dependencies
    )
    if failure == "platform":
        bundle = extensions.VerifiedExtensions(
            bundle.manifest, bundle.wheel, bundle.library, "wrong/platform.so"
        )
    elif failure == "changed-wheel":
        bundle.wheel.write_bytes(b"changed")
    elif failure == "missing-vendor":
        with zipfile.ZipFile(bundle.wheel) as source:
            files = {n: source.read(n) for n in source.namelist()}
        vendors = (
            extensions.LINUX_VENDOR_LIBRARIES
            if platform == "linux"
            else extensions.MACOS_VENDOR_LIBRARIES
        )
        del files["litert_lm/" + vendors[0]]
        with zipfile.ZipFile(bundle.wheel, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        bundle.manifest["wheel_sha256"] = extensions.file_sha256(bundle.wheel)
    elif failure == "escape":
        name = (
            extensions.LINUX_VENDOR_LIBRARIES[0]
            if platform == "linux"
            else "liblitert-lm.dylib"
        )
        output = target / name
        output.unlink(missing_ok=True)
        output.symlink_to(wheel.root / "outside")
    elif platform == "linux":
        native.write_bytes(b"corrupt")
    else:
        bundle.manifest["library_sha256"] = "0" * 64
    with pytest.raises(ValueError):
        copy(bundle, target)
    assert not (wheel.root / "outside").exists()
    assert not list(target.glob("*.part"))
