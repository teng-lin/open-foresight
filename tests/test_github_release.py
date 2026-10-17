"""Draft releases remain addressable when GitHub's tag lookup returns 404."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from github_release import release_for_tag


class GithubReleaseTest(unittest.TestCase):
    def test_exact_tag_search_includes_drafts_and_later_pages(self):
        draft = {'tag_name': 'v0.1.1', 'draft': True, 'id': 42}
        routes = []

        def request(repository, route):
            self.assertEqual(repository, 'owner/repo')
            routes.append(route)
            if route == 'releases?per_page=100&page=1':
                return [{'tag_name': 'v0.1.10', 'id': i} for i in range(100)]
            if route == 'releases?per_page=100&page=2':
                return [draft]
            raise subprocess.CalledProcessError(1, ['gh', 'api', route], stderr='HTTP 404')

        self.assertEqual(release_for_tag('owner/repo', 'v0.1.1', request=request), draft)
        self.assertEqual(routes, ['releases?per_page=100&page=1', 'releases?per_page=100&page=2'])

    def test_absence_is_optional_but_api_failures_and_ambiguity_are_errors(self):
        self.assertIsNone(release_for_tag('owner/repo', 'v0.1.1', optional=True,
                                         request=lambda *_: []))
        with self.assertRaisesRegex(ValueError, 'Release not found'):
            release_for_tag('owner/repo', 'v0.1.1', request=lambda *_: [])
        for response in ({'message': 'invalid response'},
                         [{'tag_name': 'v0.1.1'}, {'tag_name': 'v0.1.1'}]):
            with self.subTest(response=response), self.assertRaises(ValueError):
                release_for_tag('owner/repo', 'v0.1.1', request=lambda *_: response)
        error = subprocess.CalledProcessError(1, ['gh', 'api'], stderr='HTTP 403')
        with patch('github_release.api', side_effect=error) as request:
            with self.assertRaises(subprocess.CalledProcessError):
                release_for_tag('owner/repo', 'v0.1.1', optional=True, request=request)

    def test_workflow_readiness_reads_draft_list_and_still_requires_all_assets(self):
        workflow = (Path(__file__).resolve().parents[1] /
                    '.github/workflows/release-acceptance.yml').read_text()
        source = textwrap.dedent(workflow.split("python3 - <<'PYCODE'\n", 1)[1]
                                 .split('          PYCODE', 1)[0])
        assets = []
        for suffix, metadata in [('.deb', '.build.json'), ('.rpm', '.build.json'),
                                 ('.pkg.tar.zst', '.build.json'), ('.dmg', '.manifest.json')]:
            name = 'installer' + suffix
            assets.extend({'name': value} for value in (name, name + '.sha256', name + metadata))
        draft = {'tag_name': 'v0.1.1', 'draft': True, 'assets': assets}

        def response(command, **kwargs):
            if command == ['gh', 'api', 'repos/owner/repo/releases?per_page=100&page=1']:
                return json.dumps([draft])
            raise subprocess.CalledProcessError(1, command, stderr='HTTP 404')

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            with patch.dict(os.environ, {'RELEASE_TAG': 'v0.1.1', 'GITHUB_REPOSITORY': 'owner/repo',
                                         'GITHUB_OUTPUT': str(output)}), \
                    patch('ci_artifacts.subprocess.check_output', side_effect=response):
                exec(compile(source, 'release-acceptance.yml', 'exec'), {})
                self.assertEqual(output.read_text(), 'tag=v0.1.1\nready=true\n')
                output.unlink()
                draft['assets'] = assets[:-1]
                with self.assertRaisesRegex(ValueError, 'Expected exactly one'):
                    exec(compile(source, 'release-acceptance.yml', 'exec'), {})
                self.assertFalse(output.exists())
