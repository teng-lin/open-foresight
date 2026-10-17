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
    def test_created_draft_uses_list_lookup_when_tag_endpoint_is_unavailable(self):
        draft = {'tag_name': 'v0.1.1', 'id': 42, 'draft': True, 'assets': [], 'body': ''}
        lists = iter([[], [draft]])

        def response(repository, route):
            if route == 'git/matching-refs/tags/v0.1.1':
                return [{'ref': 'refs/tags/v0.1.1'}]
            if route == 'commits/v0.1.1':
                return {'sha': 'a' * 40}
            if route == 'releases?per_page=100&page=1':
                return next(lists)
            raise subprocess.CalledProcessError(1, ['gh', 'api', route], stderr='HTTP 404')

        with patch.object(release, 'api', side_effect=response), \
                patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps({**draft, 'target_commitish': 'a' * 40}))) as command:
            self.assertEqual(release.create_draft('owner/repo', 'v0.1.1', 'a' * 40), '1')
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args_list[0].args[0][:4], ['gh', 'release', 'create', 'v0.1.1'])
        self.assertIn('repos/owner/repo/releases/42', command.call_args_list[1].args[0])

    def test_package_release_increases_even_when_an_older_workflow_is_rerun(self):
        body = 'Release notes'
        for expected in (1, 2, 3):
            # The reservation is release state, so workflow age cannot lower it.
            generation = release.package_release(body)
            self.assertEqual(generation, str(expected))
            body += f'\n<!-- foresight-package-release: {generation} -->'

    def test_release_published_during_creation_is_not_modified(self):
        with patch.object(release, 'api', side_effect=[
                [{'ref': 'refs/tags/v0.1.1'}], {'sha': 'a' * 40}, [],
                [{'tag_name': 'v0.1.1', 'draft': False, 'id': 42}]]), \
                patch.object(release.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'Public releases are immutable'):
                release.create_draft('owner/repo', 'v0.1.1', 'a' * 40)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[0][:4], ['gh', 'release', 'create', 'v0.1.1'])

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
        draft = [{'tag_name': 'v0.1.1', 'id': 5, 'body': '<!-- foresight-package-release: 7 -->', 'draft': True, 'assets': [{'id': 123}]}]
        with patch.object(release, 'api', side_effect=[[{'ref': 'refs/tags/v0.1.1'}],
                                                     {'sha': 'a' * 40}, draft]), \
                patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps({**draft[0], 'target_commitish': 'a' * 40}))) as command:
            self.assertEqual(release.create_draft('owner/repo', 'v0.1.1', 'a' * 40), '8')
            self.assertEqual(command.call_count, 2)
            self.assertIn('foresight-package-release: 8', command.call_args_list[0].args[0][-1])
            self.assertEqual(command.call_args.args[0][-1], 'repos/owner/repo/releases/assets/123')

    def test_generation_reservation_explicitly_preserves_the_frozen_draft_binding(self):
        commit = 'a' * 40
        draft = {'tag_name': 'v0.1.1', 'id': 5, 'target_commitish': commit, 'draft': True,
                 'body': 'Release notes\n<!-- foresight-package-release: 7 -->', 'assets': [{'id': 123}]}
        payload = {}

        def command(arguments, **kwargs):
            if arguments[3] == 'PATCH':
                self.assertTrue(kwargs['capture_output'])
                self.assertTrue(kwargs['check'])
                for flag, field in zip(arguments[5::2], arguments[6::2]):
                    key, value = field.split('=', 1)
                    payload[key] = json.loads(value) if flag == '-F' else value
                # Reproduce the live body-only PATCH failure if identity is omitted.
                response = {**draft, **payload,
                            'tag_name': payload.get('tag_name', 'vGitHubuntagged-fixture')}
                return subprocess.CompletedProcess(arguments, 0, json.dumps(response))
            self.assertEqual(arguments[3], 'DELETE')
            self.assertEqual(payload['tag_name'], 'v0.1.1')
            self.assertEqual(payload['target_commitish'], commit)
            self.assertIs(payload['draft'], True)
            self.assertEqual(payload['body'], 'Release notes\n<!-- foresight-package-release: 8 -->')
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(release, 'api', side_effect=[
                [{'ref': 'refs/tags/v0.1.1'}], {'sha': commit}, [draft]]), \
                patch.object(release.subprocess, 'run', side_effect=command) as process:
            self.assertEqual(release.create_draft('owner/repo', 'v0.1.1', commit), '8')
        self.assertEqual(process.call_count, 2)

    def test_unexpected_patch_response_never_deletes_draft_assets(self):
        commit = 'a' * 40
        draft = {'tag_name': 'v0.1.1', 'id': 5, 'target_commitish': commit, 'draft': True,
                 'body': '', 'assets': [{'id': 123}]}
        for change in ({'tag_name': 'vGitHubuntagged-fixture'}, {'id': 6},
                       {'target_commitish': 'b' * 40}, {'draft': False}, {'draft': 'true'}):
            with self.subTest(change=change), patch.object(release, 'api', side_effect=[
                    [{'ref': 'refs/tags/v0.1.1'}], {'sha': commit}, [draft]]), \
                    patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess(
                        [], 0, json.dumps({**draft, **change}))) as command:
                with self.assertRaisesRegex(ValueError, 'immutable release binding'):
                    release.create_draft('owner/repo', 'v0.1.1', commit)
                self.assertEqual(command.call_count, 1)
                self.assertEqual(command.call_args.args[0][3], 'PATCH')
