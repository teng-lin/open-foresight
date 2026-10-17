#!/usr/bin/env python3
"""Build exact-main candidates before creating an immutable tag and draft release."""
import argparse
import json
import os
import re
import subprocess
import time

from app_version import read_version, stale
from ci_artifacts import api, name, trusted_run


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
        raise ValueError('Dispatch release preparation from the current main commit')
    subprocess.run(['gh', 'workflow', 'run', 'macos.yml', '--repo', repository, '--ref', 'main'], check=True)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if candidates_ready(repository, commit):
            return
        print(f'Waiting for exact-commit main candidates: {commit}', flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))
    raise TimeoutError('Candidates unavailable; no release tag was created. Inspect macos.yml and retry.')


def package_release(run_number, attempt):
    """Later runs and re-runs must sort after every previous package build."""
    if run_number < 1 or not 1 <= attempt < 1000:
        raise ValueError('Invalid workflow run number or attempt')
    return str(run_number * 1000 + attempt)


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
    releases = api(repository, 'releases?per_page=100')
    release = next((item for item in releases if item['tag_name'] == tag), None)
    if release:
        if not release['draft']:
            raise ValueError('Public releases are immutable; cut a new version')
        # A full rebuild replaces only unpublished assets and receives a higher
        # package release. Never mix old installers with the new acceptance run.
        for asset in release['assets']:
            subprocess.run(['gh', 'api', '--method', 'DELETE',
                            f'repos/{repository}/releases/assets/{asset["id"]}'], check=True)
        return
    subprocess.run(['gh', 'release', 'create', tag, '--repo', repository, '--verify-tag',
                    '--draft', '--title', 'Open Foresight ' + tag, '--generate-notes'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', 'teng-lin/open-foresight'))
    parser.add_argument('--wait', type=int, default=10800)
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag) or args.tag != 'v' + read_version()[0] or stale():
        raise ValueError('Release tag must match the synchronized application version')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Release preparation requires reviewed main')
    require_candidates(args.repo, commit, args.wait)
    create_draft(args.repo, args.tag, commit)
    release = package_release(int(os.environ['GITHUB_RUN_NUMBER']), int(os.environ['GITHUB_RUN_ATTEMPT']))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'tag={args.tag}\npackage_release={release}\ncommit={commit}\n')


if __name__ == '__main__':
    main()
