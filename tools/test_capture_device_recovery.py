#!/usr/bin/env python3
"""Verify private PipeWire device loss/return without physical recording."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def command(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def audio_defaults():
    return {kind: command('pactl', 'get-default-' + kind)
            for kind in ('sink', 'source')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--microphone', action='store_true')
    parser.add_argument('--library', type=Path,
                        default=ROOT / 'build/native/libforesight_native.so')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    lib = C.CDLL(str(args.library.resolve()))
    lib.fs_capture_start.argtypes = [C.c_char_p, C.c_int, C.c_int]
    lib.fs_capture_start.restype = C.c_void_p
    lib.fs_event_poll.argtypes = [C.c_void_p, C.c_int]
    lib.fs_event_poll.restype = C.c_void_p
    lib.fs_string_free.argtypes = [C.c_void_p]
    lib.fs_string_free.restype = None
    lib.fs_capture_stop.argtypes = [C.c_void_p]
    lib.fs_capture_stop.restype = None
    name = 'foresight-recovery-' + str(os.getpid())
    target = name + '-microphone' if args.microphone else name
    modules, stages = [], {}
    handle = player = None

    def add_device():
        modules.append(command(
            'pactl', 'load-module', 'module-null-sink', 'sink_name=' + name,
            'channels=1', 'rate=48000', 'sink_properties=priority.session=0'))
        if args.microphone:
            modules.append(command(
                'pactl', 'load-module', 'module-remap-source',
                'master=' + name + '.monitor', 'source_name=' + target,
                'channels=1', 'source_properties=priority.session=0'))

    def remove_device():
        for module in reversed(modules.copy()):
            command('pactl', 'unload-module', module)
            modules.remove(module)

    def play_fixture():
        # Test playback must also stay on the private device if it disappears.
        return subprocess.Popen([
            'pw-play', '--properties',
            '{ node.dont-fallback = true node.dont-reconnect = true }',
            '--target', name, str(ROOT / 'tests/fixtures/audio/jfk.wav')])

    def stop_player():
        if player is not None and player.poll() is None:
            player.terminate()
            player.wait(timeout=5)

    def sample(stage, seconds):
        events, pcm, after_gap, peak = [], 0, 0, 0
        seen_gap = False
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pointer = lib.fs_event_poll(handle, 100)
            if not pointer:
                continue
            try:
                event = json.loads(C.string_at(pointer))
            finally:
                lib.fs_string_free(pointer)
            if event['type'] == 'pcm':
                pcm += 1
                peak = max(peak, event.get('volume', 0))
                if seen_gap:
                    after_gap += 1
            else:
                events.append(event)
                if event['type'] == 'gap':
                    seen_gap = True
        stages[stage] = {'pcm_frames': pcm, 'pcm_after_first_gap': after_gap,
                         'peak_rms': peak, 'events': events}

    before = audio_defaults()
    try:
        add_device()
        time.sleep(.5)
        handle = lib.fs_capture_start(target.encode(), 0 if args.microphone else 1, 48000)
        assert handle, 'Native capture failed to start'
        player = play_fixture()
        sample('before_loss', 2)
        remove_device()
        time.sleep(1)
        sample('device_absent', 3)
        add_device()
        time.sleep(.5)
        stop_player()
        player = play_fixture()
        sample('device_returned', 7)
    finally:
        if handle:
            lib.fs_capture_stop(handle)
        stop_player()
        remove_device()
    after = audio_defaults()
    report = {
        'method': 'Real native capture and private PipeWire device removal/return; known JFK fixture; no physical microphone',
        'capture_channel': 'microphone' if args.microphone else 'playback',
        'stages': stages,
        'host_default_audio_devices_before': before,
        'host_default_audio_devices_after': after,
        'host_default_audio_devices_preserved': before == after,
        # Frames queued before the gap are valid captured samples; only frames
        # after the native loss event would violate the absent-device gate.
        'no_pcm_after_loss_event': stages['device_absent']['pcm_after_first_gap'] == 0,
        'recovered_pcm_after_device_return': stages['device_returned']['peak_rms'] > .01,
        'limitation': 'Virtual device recovery; physical hardware, default-device changes, suspend and transcription recovery remain separate',
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    assert report['host_default_audio_devices_preserved']
    assert stages['before_loss']['peak_rms'] > .01
    assert report['no_pcm_after_loss_event']
    assert report['recovered_pcm_after_device_return']
    assert any(event['type'] == 'gap' for event in stages['device_absent']['events'])


if __name__ == '__main__':
    main()
