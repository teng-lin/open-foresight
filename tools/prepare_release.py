#!/usr/bin/env python3
"""Build exact-main candidates before creating an immutable tag and draft release."""
import argparse
import base64
import json
import os
import re
import subprocess
import time

from app_version import PUBSPEC, SOURCE, read_version, stale
from ci_artifacts import api, name, trusted_run
from github_release import release_for_tag


def candidates_ready(repository, commit):
    for component in ('linux-app', 'macos-app'):
        artifact_name = name(component, commit)
        artifacts = api(repository, f'actions/artifacts?name={artifact_name}&per_page=100')['artifacts']
        qualified = False
        for artifact in artifacts:
            if artifact['expired'] or artifact['name'] != artifact_name:
                continue
            run = api(repository, f'actions/runs/{artifact["workflow_run"]["id"]}')
            if run['head_sha'] == commit and trusted_run(run, component, repository=repository):
                qualified = True
                break
        if not qualified:
            return False
    return True


def require_candidates(repository, commit, wait):
    if candidates_ready(repository, commit):
        return
    if api(repository, 'commits/main')['sha'] != commit:
        raise ValueError('Exact-commit candidates are unavailable; refusing to substitute a newer main build')
    subprocess.run(['gh', 'workflow', 'run', 'macos.yml', '--repo', repository, '--ref', 'main'], check=True)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if candidates_ready(repository, commit):
            return
        print(f'Waiting for exact-commit main candidates: {commit}', flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))
    raise TimeoutError('Candidates unavailable; no release tag was created. Inspect macos.yml and retry.')


def package_release(body):
    """Reserve the next draft generation independently of workflow run order."""
    markers = re.findall(r'<!-- foresight-package-release: ([0-9]+) -->', body)
    return str(max([0, *map(int, markers)]) + 1)


def release_source(repository, tag, control_commit):
    """Resume an immutable reviewed tag, or prepare the current main commit."""
    refs = api(repository, f'git/matching-refs/tags/{tag}')
    if not any(ref['ref'] == f'refs/tags/{tag}' for ref in refs):
        return control_commit
    commit = api(repository, f'commits/{tag}')['sha']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Release tag must resolve to a full source commit')
    comparison = api(repository, f'compare/{commit}...{control_commit}')
    if comparison['status'] not in ('ahead', 'identical'):
        raise ValueError('Release tag must be reachable from reviewed main')
    pubspec = api(repository, f'contents/{PUBSPEC}?ref={commit}')
    if pubspec.get('encoding') != 'base64':
        raise ValueError('Cannot verify the tagged application version')
    text = base64.b64decode(''.join(pubspec['content'].split()), validate=True).decode('utf-8')
    version = SOURCE.search(text)
    if not version or tag != 'v' + version[1]:
        raise ValueError('Release tag must match its immutable application version')
    return commit


def create_draft(repository, tag, commit):
    # Querying refs explicitly distinguishes absence from API/auth failures.
    refs = api(repository, f'git/matching-refs/tags/{tag}')
    existing = [ref for ref in refs if ref['ref'] == f'refs/tags/{tag}']
    if existing:
        if api(repository, f'commits/{tag}')['sha'] != commit:
            raise ValueError('Existing release tag points to a different commit')
    else:
        subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{repository}/git/refs',
                        '-f', f'ref=refs/tags/{tag}', '-f', f'sha={commit}'], check=True)
    release = release_for_tag(repository, tag, optional=True, request=api)
    if release is None:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', repository, '--verify-tag',
                        '--draft', '--title', 'Open Foresight ' + tag, '--generate-notes'], check=True)
        release = release_for_tag(repository, tag, request=api)
    if not release['draft']:
        raise ValueError('Public releases are immutable; cut a new version')
    body = release.get('body') or ''
    generation = package_release(body)
    body = re.sub(r'\n?<!-- foresight-package-release: [0-9]+ -->', '', body)
    body += f'\n<!-- foresight-package-release: {generation} -->'
    # Persist the reservation before deleting anything. Retrying an old workflow
    # still advances the draft generation, even after a partially failed rebuild.
    updated = subprocess.run(['gh', 'api', '--method', 'PATCH',
                              f'repos/{repository}/releases/{release["id"]}',
                              '-f', f'tag_name={tag}', '-f', f'target_commitish={commit}',
                              '-F', 'draft=true', '-f', 'body=' + body],
                             check=True, capture_output=True, text=True)
    metadata = json.loads(updated.stdout)
    if (metadata.get('id') != release['id'] or metadata.get('tag_name') != tag or
            metadata.get('target_commitish') != commit or metadata.get('draft') is not True):
        raise ValueError('Draft metadata update changed the immutable release binding; assets were not deleted')
    for asset in release['assets']:
        subprocess.run(['gh', 'api', '--method', 'DELETE',
                        f'repos/{repository}/releases/assets/{asset["id"]}'], check=True)
    return generation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', 'teng-lin/open-foresight'))
    parser.add_argument('--wait', type=int, default=10800)
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag) or stale():
        raise ValueError('Release requires a stable tag and synchronized application version')
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Release preparation requires reviewed main')
    control_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    commit = release_source(args.repo, args.tag, control_commit)
    if commit == control_commit and args.tag != 'v' + read_version()[0]:
        raise ValueError('A new release tag must match the synchronized application version')
    require_candidates(args.repo, commit, args.wait)
    release = create_draft(args.repo, args.tag, commit)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'tag={args.tag}\npackage_release={release}\ncommit={commit}\ncontrol_commit={control_commit}\n')
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            stream.write(f'Product tag: `{args.tag}`\n\nProduct commit: `{commit}`\n\nControl commit: `{control_commit}`\n')


if __name__ == '__main__':
    main()
