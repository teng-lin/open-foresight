"""The desktop pubspec is the only place the release version is written."""

from pathlib import Path
import shutil

import pytest

from tools import app_version

ROOT = Path(__file__).resolve().parents[2]
# Files that must derive the version rather than repeat it.
DERIVING = [
    "CMakeLists.txt",
    "services/helper/CMakeLists.txt",
    "packages/foresight_core/bin/mcp.dart",
    "tools/package.py",
    "tools/package_macos.py",
    *[
        str(path.relative_to(ROOT))
        for path in sorted((ROOT / "apps/desktop/lib").rglob("*.dart"))
    ],
]


def copy_tree(tmp_path):
    for path in (
        app_version.PUBSPEC,
        app_version.CORE_PUBSPEC,
        app_version.DESKTOP_LOCK,
        app_version.DART_VERSION,
    ):
        (tmp_path / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / path, tmp_path / path)
    return tmp_path


def test_checked_in_copies_match_pubspec():
    assert app_version.stale() == []


@pytest.mark.parametrize("path", DERIVING)
def test_sources_do_not_hardcode_the_version(path):
    version, _ = app_version.read_version()
    assert f"'{version}'" not in (ROOT / path).read_text()
    assert f"-{version}" not in (ROOT / path).read_text()


def test_set_updates_every_copy_and_bumps_build(tmp_path):
    root = copy_tree(tmp_path)
    _, build = app_version.read_version(root)
    assert app_version.set_version("9.8.7", root=root) == ("9.8.7", build + 1)
    assert app_version.read_version(root) == ("9.8.7", build + 1)
    assert app_version.stale(root) == []
    assert (
        "openForesightVersion = '9.8.7'"
        in (root / app_version.DART_VERSION).read_text()
    )
    assert "version: 9.8.7\n" in (root / app_version.CORE_PUBSPEC).read_text()
    assert 'version: "9.8.7"' in (root / app_version.DESKTOP_LOCK).read_text()


def test_stale_reports_a_hand_edited_pubspec(tmp_path):
    root = copy_tree(tmp_path)
    pubspec = root / app_version.PUBSPEC
    pubspec.write_text(app_version.SOURCE.sub("version: 9.9.9+99", pubspec.read_text()))
    assert app_version.stale(root) == sorted(
        [app_version.CORE_PUBSPEC, app_version.DESKTOP_LOCK, app_version.DART_VERSION]
    )


@pytest.mark.parametrize(
    "version, build", [("1.2", None), ("v1.2.3", None), ("01.2.3", None), ("1.2.3", 1)]
)
def test_set_rejects_invalid_versions_and_non_increasing_builds(
    tmp_path, version, build
):
    root = copy_tree(tmp_path)
    with pytest.raises(ValueError):
        app_version.set_version(version, build, root=root)
    if version == "01.2.3":
        pubspec = root / app_version.PUBSPEC
        pubspec.write_text(
            app_version.SOURCE.sub("version: 01.2.3+99", pubspec.read_text())
        )
        with pytest.raises(ValueError):
            app_version.stale(root)
