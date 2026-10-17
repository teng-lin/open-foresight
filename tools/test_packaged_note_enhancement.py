#!/usr/bin/env python3
"""Real packaged Application enhancement, including saved-transcript correction.

Only an isolated synthetic profile is changed. The input bundle and model files
are read-only inputs. This scenario tests observed content, not general quality.
"""
import argparse
import json
from pathlib import Path
import re
import tempfile
import time

from install_macos import minimal_environment
from installed_runtime import layout, process_path, service_command, wait_stopped
from smoke_macos_bundle import ApplicationPeer, McpPeer
from test_packaged_model_runtime import (
    digest, packaged_paths, GENERATION_SHA256, EMBEDDING_SHA256)


def enhanced(meeting, deadline):
    artifacts = [row for row in meeting['artifacts'] if row['kind'] == 'enhanced_notes']
    if not artifacts:
        raise AssertionError('Application did not save enhanced notes')
    result = artifacts[-1]
    text = result['edited'] or result['generated']
    main = text.split('Potential Important Topics Not In Notes', 1)[0]
    bullets = [line for line in main.splitlines()
               if re.match(r'^\s*[-*+•]\s+', line)]
    clauses = [clause for bullet in bullets for clause in re.split(r'[.;]', bullet)]
    def affirmative(clause):
        if deadline.lower() == 'friday':
            clause = re.sub(r'\bnot\s+(?:on\s+)?Tuesday\b', '', clause, flags=re.I)
        return not re.search(r'\b(?:not|never|instead of|rather than)\b.*\b'
                             + deadline + r'\b', clause, re.I)
    if not any(all(re.search(r'\b' + word + r'\b', clause, re.I)
                   for word in ('mira', 'draft', deadline.lower()))
               and affirmative(clause)
               for clause in clauses):
        raise AssertionError(f'Enhanced notes omit the explicit {deadline} deadline: {text!r}')
    if deadline.lower() == 'friday':
        # A correction in missed topics or a different person's deadline must
        # not make a stale accepted Tuesday bullet look successful.
        residual = re.sub(r'\b(?:not|instead of|rather than)\s+(?:on\s+)?Tuesday\b', '', main, flags=re.I)
        residual = re.sub(r'\bfrom\s+Tuesday\s+to\s+Friday\b', '', residual, flags=re.I)
        if re.search(r'\bTuesday\b', residual, re.I):
            raise AssertionError(f'Enhanced notes retain an affirmative Tuesday deadline: {text!r}')
    return result


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'failed', 'stage': 'inputs', 'embedding_backend': args.backend, 'scenario':
        'saved_transcript_Tuesday_to_Friday_without_force_regenerate'}
    profile = None
    mcp = application = None
    owner = None
    env = None
    service = None
    failure = None
    cleanup_errors = []
    try:
        bundle = args.bundle.resolve(strict=True)
        runner, _, _ = packaged_paths(bundle)
        configuration = (json.loads((bundle / 'Contents/Resources/runtime.json').read_text())
                         if bundle.suffix == '.app' else {})
        report['generation_backend'] = configuration.get('FORESIGHT_LITERT_BACKEND', 'cpu')
        for name, path, expected in (
            ('generation', args.generation, GENERATION_SHA256),
            ('embedding', args.embedding, EMBEDDING_SHA256)):
            actual = digest(path)
            if actual != expected:
                raise ValueError(f'{name} is not the production catalog model: {actual}')
            report[name + '_sha256'] = actual
        executable, service = layout(bundle)
        executable, service = executable.resolve(strict=True), service.resolve(strict=True)
        if not all(path.is_relative_to(bundle) for path in (service, executable)):
            raise ValueError('Application executables escape the bundle')
        profile = Path(tempfile.mkdtemp(prefix='of-note-package-', dir='/tmp'))
        home, data, runtime = (profile / name for name in ('home', 'data', 'run'))
        for path in (home, data, runtime):
            path.mkdir(mode=0o700)
        env = minimal_environment(home, data)
        env['FORESIGHT_RUNTIME'] = str(runtime)
        report['synthetic_profile'] = str(profile)
        report['stage'] = 'application_startup'
        mcp = McpPeer(executable, env)
        state = mcp.tool('get_status')
        owner = state['pid']
        if process_path(owner) != service or state['installation_root'] != str(bundle):
            raise AssertionError('MCP attached outside the requested bundle/profile')
        report['runtime_revision'] = state.get('runtime_revision')
        report['service_pid'] = owner
        application = ApplicationPeer(runtime / 'application.sock')
        application.socket.settimeout(args.timeout)
        for key in ('liveEnhance', 'proactiveAnswers'):
            application.call('preferences.set', {'key': key, 'value': 'false'})
        report['stage'] = 'model_configuration'
        application.call('models.embedding', {'path': str(args.embedding.resolve()),
            'runtime': '', 'gpu': args.backend == 'gpu', 'digest': EMBEDDING_SHA256})
        application.call('models.generation', {'path': str(args.generation.resolve()),
            'runtime': str(runner), 'backend': 'litert_lm'})
        deadline = time.monotonic() + args.timeout
        while True:
            state = application.call('status')
            helper = state.get('helper') or {}
            if helper.get('pipeline') == 'ready' and helper.get('tokenizerReady') is True:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(f'Helper lacks real embedding/tokenizer readiness: {helper!r}')
            time.sleep(.2)
        report['helper'] = helper
        identifier = application.call('meetings.create', {'title': 'Synthetic draft deadline'})['id']
        application.call('meetings.notes', {'id': identifier, 'body': 'Mira draft deadline'})
        first_text = 'Mira will send the draft on Tuesday. Theo will review it on Wednesday.'
        correction = 'Correction: Mira will send the draft on Friday, not Tuesday. Friday is the final deadline.'
        report['requests'] = [first_text, correction]
        report['stage'] = 'first_enhancement'
        application.call('meetings.transcript', {'id': identifier, 'text': first_text})
        application.call('meetings.enhance', {'id': identifier})
        first = application.call('meetings.get', {'id': identifier})
        report['first_meeting'] = first
        initial = enhanced(first, 'Tuesday')
        report['stage'] = 'saved_append_enhancement'
        application.call('meetings.transcript', {'id': identifier, 'text': correction})
        application.call('meetings.enhance', {'id': identifier})
        second = application.call('meetings.get', {'id': identifier})
        report['second_meeting'] = second
        updated = enhanced(second, 'Friday')
        if updated['input_revision'] <= initial['input_revision']:
            raise AssertionError('Saved transcript append did not advance enhancement input revision')
        if updated['id'] <= initial['id']:
            raise AssertionError('Application did not persist a newer enhancement artifact')
        if len(second['transcript']) != len(first['transcript']) + 1:
            raise AssertionError('Saved correction was not appended exactly once')
        if second['transcript'][-1]['text'] != correction:
            raise AssertionError('Saved transcript differs from the requested correction')
        if getattr(args, 'acceptance', False):
            report['stage'] = 'indexed_grounded_answer'
            source = application.call('sources.import', {
                'title': 'Acceptance Project Marigold',
                'text': 'Project Marigold has launch code 7319. Mira owns Project Marigold.'})
            answer = application.call('answer', {
                'question': "What is Project Marigold's launch code?", 'conversation': 'release-acceptance'})['text']
            report['grounded_answer'] = {'text': answer, 'source_id': source['id']}
            if '7319' not in answer or not re.search(r'\[S?\d+\]', answer):
                raise AssertionError('Grounded answer omitted the known fact or citation')
            note = mcp.tool('save_note', {'title': 'Release persistence', 'body': 'Persisted installed note'})
            report['stage'] = 'service_restart'
            application.close()
            application = None
            mcp.close()
            mcp = None
            service_command(service, env, '--stop')
            wait_stopped(owner, service)
            previous_owner = owner
            owner = None
            mcp = McpPeer(executable, env)
            state = mcp.tool('get_status')
            owner = state['pid']
            if owner == previous_owner or process_path(owner) != service:
                raise AssertionError('Restart did not create the requested installed service')
            application = ApplicationPeer(runtime / 'application.sock')
            application.socket.settimeout(args.timeout)
            restored = application.call('meetings.get', {'id': identifier})
            enhanced(restored, 'Friday')
            if not any(row['id'] == note['id'] and row['body'] == 'Persisted installed note'
                       for row in mcp.tool('list_notes')):
                raise AssertionError('Installed note was not restored')
            if mcp.tool('get_source', {'id': source['id']})['content'] != \
                    'Project Marigold has launch code 7319. Mira owns Project Marigold.':
                raise AssertionError('Installed source was not restored')
            report['restart_persistence'] = 'passed'
        report['status'] = 'passed'
        report['stage'] = 'completed'
    except BaseException as error:
        failure = error
        report['error'] = f'{type(error).__name__}: {error}'
    finally:
        for peer in (application, mcp):
            if peer is not None:
                try:
                    peer.close()
                except Exception as error:
                    cleanup_errors.append(str(error))
        if service is not None and env is not None:
            try:
                # Authenticate the disposable profile even if startup failed
                # before the MCP status reply supplied the owner PID.
                current = service_command(service, env, '--status')
                current_owner = current['pid']
                if process_path(current_owner) != service:
                    raise RuntimeError('Refusing to stop a service outside this bundle')
                if owner is not None and owner != current_owner:
                    raise RuntimeError('Disposable service owner changed unexpectedly')
                service_command(service, env, '--stop')
                wait_stopped(current_owner, service, timeout=30)
                report['service_shutdown'] = 'verified_stopped'
            except Exception as error:
                cleanup_errors.append(str(error))
        if mcp is not None:
            try:
                (output / 'mcp.stderr.log').write_bytes(mcp.errors)
            except Exception as error:
                cleanup_errors.append(f'Cannot persist MCP stderr: {error}')
        if cleanup_errors:
            report['cleanup_errors'] = cleanup_errors
            report['status'] = 'failed'
            if failure is None:
                report['stage'] = 'cleanup'
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if failure is not None:
        raise failure
    if cleanup_errors:
        raise RuntimeError('; '.join(cleanup_errors))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--acceptance', action='store_true', help='Also verify indexed Q&A and restart persistence')
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--generation', type=Path, required=True)
    parser.add_argument('--embedding', type=Path, required=True)
    parser.add_argument('--backend', choices=('cpu', 'gpu'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=600)
    print(json.dumps(run(parser.parse_args()), indent=2))
