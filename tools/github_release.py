"""Look up published and draft releases through GitHub's authenticated list API."""

from typing import Any

from importlib import import_module

api = import_module("tools.ci_artifacts" if __package__ else "ci_artifacts").api


def release_for_tag(repository, tag, *, optional=False, request=api):
    # The release-by-tag endpoint can return 404 for an existing draft. Listing
    # authenticated releases includes drafts, and older tags may be on later pages.
    matches: list[Any] = []
    page = 1
    while True:
        releases = request(repository, f"releases?per_page=100&page={page}")
        if not isinstance(releases, list):
            raise ValueError("Expected a GitHub release list")
        matches.extend(release for release in releases if release["tag_name"] == tag)
        if len(releases) < 100:
            break
        page += 1
    if len(matches) > 1:
        raise ValueError("Expected exactly one release for tag: " + tag)
    if matches:
        return matches[0]
    if optional:
        return None
    raise ValueError("Release not found for tag: " + tag)
