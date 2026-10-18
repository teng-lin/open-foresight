"""Publishing old patches must not move Latest backwards."""

from tools.release_latest import is_latest


def test_latest_compares_numeric_semantic_versions_and_ignores_unpublished():
    releases = [
        {"tag_name": "v0.2.0"},
        {"tag_name": "v9.0.0", "draft": True},
        {"tag_name": "v8.0.0", "prerelease": True},
    ]
    assert not is_latest("v0.1.9", releases)
    assert is_latest("v0.2.0", releases)
    assert is_latest("v0.10.0", releases)
    assert not is_latest("v0.3.0-rc.1", releases)
    assert is_latest("v0.2.0+build.2", releases)
