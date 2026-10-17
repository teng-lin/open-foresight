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
        observed.append((package, dict(env)))
        return {'passed': expected, 'skipped': 0}
    with patch.object(gates, 'model_file', return_value='/fixture/model'), \
            patch.object(gates, 'private_pipewire', side_effect=lambda env, output: nullcontext(env)), \
            patch.object(gates, 'run_tests', side_effect=run):
        gates.audio_gate(args, {'PATH': '/bin'})
    assert observed[0][0] == 'desktop' and observed[0][1]['FORESIGHT_WHISPER_RUNTIME'] == str(runner)
    assert observed[1][0] == 'core' and 'FORESIGHT_WHISPER_RUNTIME' not in observed[1][1]


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
