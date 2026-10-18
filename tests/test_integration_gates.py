"""Contract tests for acceptance evidence, isolation and skip-inventory drift."""
from contextlib import nullcontext
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import integration_gates as gates
import check_integration_inventory as inventory


def write_events(path, **changes):
    event = dict(type='testDone', hidden=False, skipped=False, result='success')
    event.update(changes)
    path.write_text(json.dumps(event) + '\n' + json.dumps(dict(type='done', success=True)) + '\n')


def test_expected_executed_tests_are_required(tmp_path):
    path = tmp_path / 'events.jsonl'
    write_events(path)
    assert gates.check_events(path, 1) == {'passed': 1, 'skipped': 0}
    for changes in [dict(skipped=True), dict(hidden=True), dict(result='error')]:
        write_events(path, **changes)
        with pytest.raises(RuntimeError): gates.check_events(path, 1)
    path.write_text('{"type":"done","success":true}\n')
    with pytest.raises(RuntimeError): gates.check_events(path, 1)


def test_failed_run_cannot_reuse_stale_evidence(tmp_path):
    path = tmp_path / 'probe.events.jsonl'
    write_events(path)
    with patch.object(gates.subprocess, 'run', return_value=type('Result', (), {'returncode': 1})()):
        with pytest.raises(RuntimeError):
            gates.run_tests('desktop', ['test/example.dart'], 1, dict(os.environ), tmp_path, 'probe')
    assert not path.exists()


def test_native_bundle_overrides_do_not_inherit_accounts_or_capture_routes(tmp_path):
    for relative in ['lib/libforesight_native.so', 'bin/ForesightHelper', 'bin/foresight-model']:
        file = tmp_path / relative; file.parent.mkdir(exist_ok=True); file.touch()
    env = gates.bundle_environment(tmp_path, {'PATH': '/bin', 'FORESIGHT_DATA': '/private/profile',
        'FORESIGHT_GOOGLE_CLIENT': '/private/account', 'FORESIGHT_MICROPHONE_TARGET': 'host-mic'})
    assert 'FORESIGHT_DATA' not in env and 'FORESIGHT_GOOGLE_CLIENT' not in env
    assert 'FORESIGHT_MICROPHONE_TARGET' not in env
    assert env['FORESIGHT_LITERT_BACKEND'] == 'cpu'
    assert env['FORESIGHT_NATIVE'] == str(tmp_path / 'lib/libforesight_native.so')


def test_virtual_audio_refuses_host_devices(tmp_path):
    real_exists = Path.exists
    def exists(path):
        return True if str(path) == '/dev/snd' else real_exists(path)
    with patch.object(gates.sys, 'platform', 'linux'), patch.object(Path, 'exists', exists):
        with pytest.raises(RuntimeError, match='without host sound'):
            with gates.private_pipewire({}, tmp_path): pass


def test_inventory_catches_added_removed_or_changed_skips(tmp_path):
    (tmp_path / 'tools').mkdir()
    directory = tmp_path / 'apps/desktop/test'; directory.mkdir(parents=True)
    source = directory / 'fixture.dart'; source.write_text('test("x", () {},\n skip: flag != "1",\n);')
    entry = dict(path='apps/desktop/test/fixture.dart', gate='models', reason='Public fixture', conditions=['flag != "1"'])
    (tmp_path / 'tools/integration_skips.json').write_text(json.dumps(dict(schema=1, entries=[entry])))
    assert inventory.verify(tmp_path) == 1
    for text in ['test("x", () {});', 'test("x", () {},\n skip: true,\n);']:
        source.write_text(text)
        with pytest.raises(ValueError, match='changed skip'): inventory.verify(tmp_path)


def test_repository_skip_inventory_is_current():
    assert inventory.verify(ROOT) > 0


def test_waveform_inspector_does_not_inherit_whisper_runtime(tmp_path):
    runner = tmp_path / 'bin/whisper-cli-vulkan'
    runner.parent.mkdir(); runner.touch()
    args = SimpleNamespace(bundle=tmp_path, models=tmp_path, output=tmp_path, flutter='flutter', dart='dart')
    observed = []
    def run(package, files, expected, env, *rest):
        observed.append((package, list(files), dict(env), expected))
        return {'passed': expected, 'skipped': 0}
    def pipewire(env, output):
        return nullcontext(dict(env, FORESIGHT_LIVE_SINK='ci-sink', FORESIGHT_MICROPHONE_TARGET='ci-mic'))
    with patch.object(gates, 'model_file', return_value='/fixture/model'), \
            patch.object(gates, 'private_pipewire', side_effect=pipewire), \
            patch.object(gates, 'run_tests', side_effect=run):
        gates.audio_gate(args, {'PATH': '/bin'})
    assert observed[0][0] == 'desktop' and observed[0][2]['FORESIGHT_WHISPER_RUNTIME'] == str(runner)
    assert observed[1][0] == 'core' and 'FORESIGHT_WHISPER_RUNTIME' not in observed[1][2]
    assert observed[2][1] == ['integration_test/meeting_workflow_test.dart']
    assert observed[2][3] == 1
    meeting = observed[2][2]
    assert meeting['FORESIGHT_PLAYBACK_TARGET'] == 'ci-sink'
    assert meeting['FORESIGHT_PRIVATE_PIPEWIRE'] == '1'
    assert meeting['FORESIGHT_AUDIO_FIXTURE'].endswith('tests/fixtures/audio/jfk.wav')
    assert meeting['FORESIGHT_DATA'].endswith('/meeting-data')
    assert meeting['FORESIGHT_REFERENCE_SCREENSHOTS'].endswith('/meeting-screenshots')
    assert meeting['FORESIGHT_MEETING_REPORT'].endswith('/meeting-workflow.json')
    assert 'FORESIGHT_PLAYBACK_TARGET' not in observed[0][2]


def test_private_profile_is_readable_after_the_suite(tmp_path):
    private = tmp_path / 'meeting-data' / 'nested'
    private.mkdir(parents=True)
    (tmp_path / 'meeting-data').chmod(0o700)
    private.chmod(0o700)
    secret = private / 'profile.db'
    secret.write_text('rows')
    secret.chmod(0o600)
    gates.publish_report_tree(tmp_path)
    assert (tmp_path / 'meeting-data').stat().st_mode & 0o007 == 0o005
    assert private.stat().st_mode & 0o007 == 0o005
    assert secret.stat().st_mode & 0o007 == 0o004
    assert secret.read_text() == 'rows'


def test_report_tree_continues_when_the_mount_root_cannot_be_changed(tmp_path):
    private = tmp_path / 'meeting-data'
    private.mkdir()
    private.chmod(0o700)
    secret = private / 'profile.db'
    secret.write_text('rows')
    secret.chmod(0o600)
    original = Path.chmod

    def chmod(self, mode):
        if self == tmp_path:
            raise PermissionError(1, 'Operation not permitted', str(self))
        return original(self, mode)

    with patch.object(Path, 'chmod', chmod):
        gates.publish_report_tree(tmp_path)
    assert private.stat().st_mode & 0o007 == 0o005
    assert secret.stat().st_mode & 0o007 == 0o004


def test_meeting_workflow_waits_until_the_desktop_mounts():
    source = (ROOT / 'apps/desktop/integration_test/meeting_workflow_test.dart').read_text()
    start = source.index('Future<dynamic> startedWorkspace')
    helper = source[start:source.index('Future<void> captureWindow')]
    assert "find.text('Open Foresight could not start')" in helper
    assert 'find.byType(app.Workspace)' in helper
    assert 'Desktop did not start:' in helper
    assert source.count('await startedWorkspace(tester)') == 4
    assert 'await tester.pump();\n      final dynamic workspace = tester.state' not in source


def test_meeting_workflow_alias_is_outside_the_device_test_directory():
    relative = gates.widget_test_alias('integration_test/meeting_workflow_test.dart')
    alias = ROOT / 'apps/desktop' / relative
    try:
        assert relative == 'test/private_pipewire_meeting_workflow_test.dart'
        assert alias.is_symlink()
        assert alias.resolve() == (ROOT / 'apps/desktop/integration_test/meeting_workflow_test.dart').resolve()
        assert not str(alias).startswith(str(ROOT / 'apps/desktop/integration_test'))
    finally:
        alias.unlink(missing_ok=True)


def test_model_groups_both_execute_when_desktop_group_fails(tmp_path):
    args = SimpleNamespace(models=tmp_path, output=tmp_path, flutter='flutter', dart='dart')
    observed = []
    def run(package, *args):
        observed.append(package)
        if package == 'desktop': raise RuntimeError('desktop fixture failed')
        return {'passed': 1, 'skipped': 0}
    with patch.object(gates, 'model_file', return_value='/fixture/model'), \
            patch.object(gates, 'run_tests', side_effect=run):
        with pytest.raises(RuntimeError, match='desktop fixture failed'):
            gates.models_gate(args, {'FORESIGHT_LITERT_RUNNER': '/runner'})
    assert observed == ['desktop', 'core']
