"""Release ordering and exact-source candidate gates."""
import json
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import unittest
from unittest.mock import patch

from tools import prepare_release as release


class PrepareReleaseTest(unittest.TestCase):
    def test_package_release_increases_on_rebuild_and_new_run(self):
        self.assertLess(int(release.package_release(10, 1)), int(release.package_release(10, 2)))
        self.assertLess(int(release.package_release(10, 999)), int(release.package_release(11, 1)))
        for values in ((0, 1), (1, 0), (1, 1000)):
            with self.assertRaises(ValueError):
                release.package_release(*values)

    def test_candidate_requires_successful_exact_main_and_both_platforms(self):
        commit = 'a' * 40
        run = dict(head_sha=commit, path='.github/workflows/macos.yml', event='workflow_dispatch',
                   head_branch='main', conclusion='success', head_repository={'full_name': 'owner/repo'})
        def response(repository, route):
            if route.startswith('actions/artifacts?'):
                return {'artifacts': [{'name': route.split('name=')[1].split('&')[0],
                                       'expired': False, 'workflow_run': {'id': 1}}]}
            return run
        with patch.object(release, 'api', side_effect=response):
            self.assertTrue(release.candidates_ready('owner/repo', commit))
            for change in ({'conclusion': 'failure'}, {'head_sha': 'b' * 40},
                           {'head_branch': 'other'}, {'event': 'pull_request'}):
                original = dict(run)
                run.update(change)
                self.assertFalse(release.candidates_ready('owner/repo', commit))
                run.clear()
                run.update(original)
        with patch.object(release, 'api', return_value={'artifacts': []}):
            self.assertFalse(release.candidates_ready('owner/repo', commit))

    def test_missing_candidate_forces_build_before_tagging_and_timeout_leaves_no_tag(self):
        with patch.object(release, 'candidates_ready', return_value=False), \
                patch.object(release, 'api', return_value={'sha': 'a' * 40}), \
                patch.object(release.subprocess, 'run') as command:
            with self.assertRaises(TimeoutError):
                release.require_candidates('owner/repo', 'a' * 40, wait=0)
            self.assertEqual(command.call_count, 1)
            self.assertIn('macos.yml', command.call_args.args[0])
            self.assertNotIn('refs', command.call_args.args[0])

    def test_different_existing_tag_and_public_release_are_never_overwritten(self):
        refs = [{'ref': 'refs/tags/v0.1.1'}]
        with patch.object(release, 'api', side_effect=[refs, {'sha': 'b' * 40}]), \
                patch.object(release.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                release.create_draft('owner/repo', 'v0.1.1', 'a' * 40)
            command.assert_not_called()
        public = [{'tag_name': 'v0.1.1', 'draft': False}]
        with patch.object(release, 'api', side_effect=[refs, {'sha': 'a' * 40}, public]), \
                patch.object(release.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                release.create_draft('owner/repo', 'v0.1.1', 'a' * 40)
            command.assert_not_called()

    def test_draft_rebuild_removes_only_unpublished_assets(self):
        draft = [{'tag_name': 'v0.1.1', 'draft': True, 'assets': [{'id': 123}]}]
        with patch.object(release, 'api', side_effect=[[{'ref': 'refs/tags/v0.1.1'}],
                                                     {'sha': 'a' * 40}, draft]), \
                patch.object(release.subprocess, 'run') as command:
            release.create_draft('owner/repo', 'v0.1.1', 'a' * 40)
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0][-1], 'repos/owner/repo/releases/assets/123')
