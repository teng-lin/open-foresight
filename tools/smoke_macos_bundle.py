#!/usr/bin/env python3
"""Verify a relocated Mac bundle using real AOT MCP/service subprocesses.

Physical audio, signed permission attribution, local-model inference, fresh-user
installation and notarization are separate gates, explicitly reported unrun.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from install_macos import metadata, minimal_environment, process_path, copy_application, installation_lock, Deferred, SERVICE


class McpPeer:
    def __init__(self, executable, env):
        self.process = subprocess.Popen([str(executable)], cwd='/', env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.messages = queue.Queue()
        self.errors = bytearray()
        self.sequence = 0
        self.stdout_thread = threading.Thread(target=self._read, daemon=True)
        self.stderr_thread = threading.Thread(target=self._errors, daemon=True)
        self.stdout_thread.start()
        self.stderr_thread.start()
        try:
            self.request('initialize', {'protocolVersion':'2025-11-25', 'capabilities':{},
            'clientInfo':{'name':'macos-installed-smoke','version':'1'}})
            self.send({'jsonrpc':'2.0', 'method':'notifications/initialized'})
        except BaseException:
            try: self.close()
            except Exception: pass
            raise

    def _read(self):
        try:
            for line in iter(self.process.stdout.readline, b''):
                try:
                    self.messages.put(json.loads(line))
                except Exception:
                    self.messages.put(RuntimeError(f'Non-protocol MCP stdout: {line[:200]!r}'))
                    return
        finally:
            self.messages.put(EOFError('MCP closed stdout'))

    def _errors(self):
        for chunk in iter(lambda: self.process.stderr.read(4096), b''):
            self.errors.extend(chunk)
            if len(self.errors) > 65536:
                del self.errors[:-65536]

    def send(self, value):
        self.process.stdin.write((json.dumps(value)+'\n').encode())
        self.process.stdin.flush()

    def request(self, method, params, timeout=30):
        self.sequence += 1
        request_id = self.sequence
        self.send({'jsonrpc':'2.0', 'id':request_id, 'method':method, 'params':params})
        deadline = time.monotonic()+timeout
        while True:
            try:
                item = self.messages.get(timeout=max(.001, deadline-time.monotonic()))
            except queue.Empty:
                raise TimeoutError(f'MCP {method} timed out: {self.errors.decode(errors="replace")}')
            if isinstance(item, Exception):
                raise item
            if not isinstance(item, dict) or item.get('jsonrpc') != '2.0':
                raise RuntimeError(f'Invalid MCP envelope: {item!r}')
            if item.get('id') != request_id:
                if 'id' in item or 'method' not in item:
                    raise RuntimeError(f'Unexpected MCP reply: {item!r}')
                continue
            if 'error' in item:
                raise RuntimeError(f'MCP error: {item["error"]}')
            return item['result']

    def tool(self, name, arguments=None):
        value = self.request('tools/call', {'name':name, 'arguments':arguments or {}})
        if value.get('isError'):
            raise RuntimeError(f'MCP tool failed: {value}')
        return value['structuredContent']['result']

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            result = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise RuntimeError('MCP failed to exit after closing stdin')
        finally:
            self.stdout_thread.join(timeout=2)
            self.stderr_thread.join(timeout=2)
            self.process.stdout.close()
            self.process.stderr.close()
        if result:
            raise RuntimeError(f'MCP exit {result}: {self.errors.decode(errors="replace")}')
        # Validate even trailing stdout after the final request.
        while not self.messages.empty():
            item = self.messages.get_nowait()
            if isinstance(item, EOFError):
                continue
            if isinstance(item, Exception):
                raise item
            if not isinstance(item, dict) or item.get('jsonrpc') != '2.0' or 'method' not in item:
                raise RuntimeError(f'Invalid trailing MCP output: {item!r}')


def service_command(service, env, action):
    result = subprocess.run([str(service), action], cwd='/', env=env,
        capture_output=True, text=True, timeout=60, check=True)
    return json.loads(result.stdout) if action == '--status' else None


def wait_stopped(pid, executable, timeout=15):
    deadline = time.monotonic()+timeout
    while process_path(pid) == executable.resolve() and time.monotonic() < deadline:
        time.sleep(.05)
    if process_path(pid) == executable.resolve():
        raise AssertionError('Service still live after graceful stop')


def stop_desktop(process, timeout=15):
    if process.poll() is not None:
        return process.returncode
    try:
        process.terminate()
    except ProcessLookupError:
        return process.wait(timeout=timeout)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=timeout)


def smoke(bundle, output, desktop=False):
    if not __debug__:
        raise RuntimeError('Smoke verification requires assertions; run Python without -O or PYTHONOPTIMIZE')
    from macos_bundle import audit_dependencies
    report = {'gates': {key:'not_run' for key in ('desktop','desktop_window_close','physical_audio','real_models',
        'signed_permission_attribution','fresh_user','quarantine','notarization','minimum_os')}}
    with tempfile.TemporaryDirectory(prefix='of-smoke-', dir='/tmp') as temporary:
        root = Path(temporary)
        app = root / 'Relocated App With Spaces' / 'Open Foresight.app'
        app.parent.mkdir()
        copy_application(bundle, app)
        info = metadata(app)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)], check=True, capture_output=True)
        report['linkage'] = audit_dependencies(app)
        home, data, runtime = root/'home', root/'data', root/'run'
        for path in (home,data,runtime):
            path.mkdir(mode=0o700)
        env = minimal_environment(home,data)
        env['FORESIGHT_RUNTIME'] = str(runtime)
        executable, service = app/'Contents/MacOS/foresight-mcp', app/SERVICE
        peers, desktop_process = [], None
        owner = None
        try:
            desktop_owner = None
            if desktop:
                desktop_log = (root/'desktop.log').open('wb')
                try:
                    desktop_process = subprocess.Popen([str(app/'Contents/MacOS'/info['CFBundleExecutable'])],
                        cwd='/',env=env,stdout=desktop_log,stderr=desktop_log)
                    deadline = time.monotonic()+30
                    while True:
                        assert desktop_process.poll() is None, 'Desktop exited during first launch'
                        try:
                            desktop_owner = service_command(service,env,'--status')['pid']
                            break
                        except subprocess.CalledProcessError:
                            assert time.monotonic()<deadline, 'Desktop did not launch its service'
                            time.sleep(.1)
                finally:
                    desktop_log.close()
            # Both are real separately running AOT MCP processes with an env -i
            # equivalent environment; no SDK, shell init, DYLD or checkout paths.
            first = McpPeer(executable,env)
            peers.append(first)
            second = McpPeer(executable,env)
            peers.append(second)
            left, right = first.tool('get_status'), second.tool('get_status')
            owner = left['pid']
            assert owner == right['pid'], 'Two MCP adapters acquired competing owners'
            if desktop:
                assert desktop_owner == owner, 'MCP did not attach to desktop-first service'
            assert process_path(owner) == service.resolve(), 'Owner is outside relocated bundle'
            assert left['installation_root'] == str(app.resolve()), 'Service installation identity differs from relocated app'
            try:
                with installation_lock(app): pass
                raise AssertionError('Installer acquired exclusive lock over a live service')
            except Deferred:
                pass
            note = first.tool('save_note',{'title':'Installed bundle smoke', 'body':'Persist across clients and service restart'})
            notes = second.tool('list_notes')
            assert any(item['id'] == note['id'] and item['body'] == 'Persist across clients and service restart' for item in notes), notes
            if desktop:
                assert desktop_process.poll() is None, 'Desktop exited before explicit closure'
                report['desktop_exit_code'] = stop_desktop(desktop_process)
                desktop_process = None
                assert service_command(service,env,'--status')['pid'] == owner
                report['gates']['desktop'] = 'passed_desktop_first_mcp_attach_and_desktop_process_exit'
            for peer in peers:
                peer.close()
            peers.clear()
            assert service_command(service,env,'--status')['pid'] == owner, 'MCP disconnect stopped service'
            service_command(service,env,'--stop')
            wait_stopped(owner,service)
            with installation_lock(app):
                racing_env = {**env, 'FORESIGHT_DATA': str(root/'blocked-data'), 'FORESIGHT_RUNTIME': str(root/'blocked-run')}
                blocked = subprocess.run([str(service)], cwd='/', env=racing_env,
                    capture_output=True, text=True, timeout=15)
                assert blocked.returncode != 0, 'Service started while installer held exclusive maintenance lock'
                assert not (root/'blocked-data/application.db').exists(), 'Racing service opened the database during installation'
                assert 'updat' in blocked.stderr.lower() or 'install' in blocked.stderr.lower(), blocked.stderr
            third = McpPeer(executable,env)
            peers.append(third)
            replacement = third.tool('get_status')['pid']
            assert replacement != owner, 'Service was not restarted'
            owner = replacement
            assert process_path(owner) == service.resolve()
            notes = third.tool('list_notes')
            assert any(item['id'] == note['id'] and item['body'] == 'Persist across clients and service restart' for item in notes), notes
            third.close()
            peers.clear()
            service_command(service,env,'--stop')
            wait_stopped(owner,service)
            owner = None
            assert (data/'application.db').is_file()
            assert not data.stat().st_mode & 0o077 and not runtime.stat().st_mode & 0o077
            report.update({'relocation':'passed_path_with_spaces', 'cwd':'/',
                'environment_keys':sorted(env), 'two_aot_mcp_shared_owner':True,
                'mcp_stdout_protocol_only':True, 'service_survives_client_disconnect':True,
                'committed_note_survives_restart':True, 'graceful_stop_process_exit_verified':True,
                'private_profile':True, 'maintenance_lock_blocks_racing_service_start':True, 'service_pids':[left['pid'],replacement]})
        finally:
            for peer in peers:
                try: peer.close()
                except Exception: pass
            if desktop_process is not None and desktop_process.poll() is None:
                report['desktop_exit_code'] = stop_desktop(desktop_process)
            if owner is None:
                try: owner = service_command(service,env,'--status')['pid']
                except (subprocess.SubprocessError, ValueError, OSError): pass
            if owner is not None and process_path(owner) == service.resolve():
                service_command(service,env,'--stop')
                wait_stopped(owner,service)
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,indent=2)+'\n')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--desktop',action='store_true',help='Launch desktop first, attach MCP, then terminate desktop process; window-close behavior remains a physical gate')
    args = parser.parse_args(argv)
    if sys.platform != 'darwin':
        parser.error('Installed Mac bundle smoke requires macOS')
    try:
        report = smoke(args.bundle.resolve(),args.output,desktop=args.desktop)
    except Exception as error:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps({'status':'failed','error':str(error)})+'\n')
        raise
    print(json.dumps({key:value for key,value in report.items() if key != 'linkage'}))


if __name__ == '__main__':
    main()
