#!/usr/bin/env python3
"""Native ownership/lifecycle tests. Deterministic runners test control flow only.
Run: python3 tests/integration/test_native.py /path/libforesight_native.so
"""
import ctypes as C
import json
import math
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import sys

LIBRARY = sys.argv.pop(1) if len(sys.argv)>1 and sys.argv[1].endswith('.so') else os.environ.get('FORESIGHT_NATIVE_LIBRARY','build/native/libforesight_native.so')

def load(path=LIBRARY):
    lib=C.CDLL(path)
    for name,args,ret in [
        ('fs_engine_create',[C.c_char_p,C.c_char_p],C.c_void_p),
        ('fs_engine_state',[C.c_void_p],C.c_void_p),
        ('fs_engine_probe',[C.c_void_p],C.c_int),
        ('fs_engine_destroy',[C.c_void_p],C.c_int),
        ('fs_conversation_create',[C.c_void_p],C.c_void_p),
        ('fs_generate',[C.c_void_p,C.c_char_p,C.c_char_p],C.c_int),
        ('fs_generation_cancel',[C.c_void_p],C.c_int),
        ('fs_conversation_destroy',[C.c_void_p,C.c_int],C.c_int),
        ('fs_speech_create',[C.c_char_p,C.c_char_p],C.c_void_p),
        ('fs_speech_push',[C.c_void_p,C.POINTER(C.c_int16),C.c_size_t,C.c_int],C.c_int),
        ('fs_speech_finish',[C.c_void_p,C.c_char_p],C.c_int),
        ('fs_speech_destroy',[C.c_void_p],None),
        ('fs_speech_cancel',[C.c_void_p],C.c_int),
        ('fs_capture_start',[C.c_char_p,C.c_int,C.c_int],C.c_void_p),
        ('fs_capture_stop',[C.c_void_p],None),
        ('fs_event_poll',[C.c_void_p,C.c_int],C.c_void_p),
        ('fs_string_free',[C.c_void_p],None),
        ('fs_pcm_rms',[C.POINTER(C.c_int16),C.c_size_t],C.c_double),
        ('fs_resample_pcm',[C.POINTER(C.c_int16),C.c_size_t,C.c_int,C.POINTER(C.c_int16),C.c_size_t,C.c_int],C.c_size_t),
    ]:
        fn=getattr(lib,name);fn.argtypes=args;fn.restype=ret
    return lib

def owned_json(lib,pointer):
    if not pointer:return None
    try:return json.loads(C.string_at(pointer))
    finally:lib.fs_string_free(pointer)

def drain(lib,handle,timeout=10):
    output=[];deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        item=owned_json(lib,lib.fs_event_poll(handle,100))
        if item:
            output.append(item)
            if item['type']=='done':return output
    raise TimeoutError(output)

class NativeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=load()
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.path=Path(self.directory.name)
        self.model=self.path/'asset';self.model.write_text('test only')
    def tearDown(self):self.directory.cleanup()
    def runner(self,body):
        runner=self.path/'runner';runner.write_text('#!/usr/bin/env python3\n'+body);runner.chmod(0o755);return str(runner).encode()
    def engine(self,body):return self.lib.fs_engine_create(self.runner(body),str(self.model).encode())
    def test_speech_runtime_override_and_explicit_cpu(self):
        runner = self.runner('import sys\nassert "-ng" in sys.argv\nprint("GPU runtime CPU override")\n').decode()
        with patch.dict(os.environ, {'FORESIGHT_WHISPER_RUNTIME': runner,
                                     'FORESIGHT_WHISPER_BACKEND': 'cpu'}):
            speech = self.lib.fs_speech_create(b'/missing/registered-runner', str(self.model).encode())
            try:
                samples = (C.c_int16 * 1600)(*([100] * 1600))
                self.assertEqual(self.lib.fs_speech_push(speech, samples, len(samples), 16000), 0)
                self.assertEqual(self.lib.fs_speech_finish(speech, b'override'), 0)
                events = drain(self.lib, speech)
                self.assertEqual(events[-1]['status'], 'completed')
                self.assertIn('GPU runtime CPU override', next(e['text'] for e in events if e['type']=='transcript'))
            finally:
                self.lib.fs_speech_destroy(speech)
    def test_delta_order_terminal_reference_and_uniqueness(self):
        e=self.engine('import os,time\nos.write(1,b"hello ")\ntime.sleep(.05)\nos.write(1,"世界".encode())\n')
        c=self.lib.fs_conversation_create(e);self.assertEqual(self.lib.fs_engine_destroy(e),-1)
        self.assertEqual(self.lib.fs_generate(c,b'r1',b'prompt'),0)
        items=drain(self.lib,c);self.assertEqual(''.join(x['text'] for x in items if x['type']=='delta'),'hello 世界')
        self.assertEqual([x['sequence'] for x in items],list(range(len(items))))
        self.assertEqual(items[-1]['status'],'completed');self.assertIsNone(owned_json(self.lib,self.lib.fs_event_poll(c,20)))
        self.assertEqual(self.lib.fs_generate(c,b'r1',b'prompt'),-1)
        self.assertEqual(self.lib.fs_conversation_destroy(c,1),0);self.assertEqual(self.lib.fs_engine_destroy(e),0)
    def test_busy_cancel_free_and_no_child_after_release(self):
        e=self.engine('import time\ntime.sleep(60)\n');a=self.lib.fs_conversation_create(e);b=self.lib.fs_conversation_create(e)
        self.assertEqual(self.lib.fs_generate(a,b'slow',b'x'),0);self.assertEqual(self.lib.fs_generate(b,b'busy',b'x'),-1)
        self.assertEqual(self.lib.fs_conversation_destroy(a,0),-1)
        self.lib.fs_generation_cancel(a);self.lib.fs_generation_cancel(a)
        self.assertEqual(drain(self.lib,a)[-1]['status'],'cancelled')
        before=time.monotonic();self.lib.fs_conversation_destroy(a,1);self.assertLess(time.monotonic()-before,1)
        self.lib.fs_conversation_destroy(b,1);self.lib.fs_engine_destroy(e)
    def test_failed_start_error_before_single_terminal(self):
        e=self.lib.fs_engine_create(b'/missing/foresight-runtime',str(self.model).encode())
        self.assertEqual(owned_json(self.lib,self.lib.fs_engine_state(e))['state'],'configured')
        self.assertEqual(self.lib.fs_engine_probe(e),-1)
        self.assertEqual(owned_json(self.lib,self.lib.fs_engine_state(e))['state'],'failed')
        c=self.lib.fs_conversation_create(e)
        self.lib.fs_generate(c,b'failure',b'prompt');events=drain(self.lib,c)
        self.assertEqual([e['type'] for e in events],['error','done']);self.assertEqual(events[-1]['status'],'failed')
        self.lib.fs_conversation_destroy(c,1);self.lib.fs_engine_destroy(e)
    def test_audio_rms_and_conversion(self):
        samples=(C.c_int16*4)(32767,-32767,0,0)
        self.assertAlmostEqual(self.lib.fs_pcm_rms(samples,4),math.sqrt(.5),places=10)
        extreme=(C.c_int16*1)(-32768);self.assertGreater(self.lib.fs_pcm_rms(extreme,1),1)
        inp=(C.c_int16*6)(0,1000,2000,3000,4000,5000);out=(C.c_int16*3)()
        self.assertEqual(self.lib.fs_resample_pcm(inp,6,48000,out,3,24000),3);self.assertEqual(list(out),[0,2000,4000])
    def test_capture_fixed_playback_frames_and_legacy_microphone_map(self):
        runner=self.path/'pw-record';runner.write_text('#!/usr/bin/env python3\nimport os,time,sys\ntarget=sys.argv[sys.argv.index("--target")+1]\nif target != "auto":\n props=sys.argv[sys.argv.index("--properties")+1]\n assert "node.dont-fallback = true" in props\n assert "node.dont-reconnect = true" in props\nfor n in [1,500,4000,3219]:\n os.write(1,b"\\0"*n);time.sleep(.02)\ntime.sleep(60)\n');runner.chmod(0o755)
        old=os.environ['PATH'];os.environ['PATH']=str(self.path)+':'+old
        try:
            for playback,rate,target in [(0,48000,b'auto'),(1,48000,b'auto'),(1,16000,b'auto'),(0,48000,b'selected-microphone'),(1,48000,b'selected-playback')]:
                h=self.lib.fs_capture_start(target,playback,rate);frames=[];deadline=time.monotonic()+3
                while time.monotonic()<deadline:
                    event=owned_json(self.lib,self.lib.fs_event_poll(h,100))
                    if event and event['type']=='pcm':
                        frames.append(event)
                        if (playback and len(frames)==2) or (not playback and len(frames)==3):break
                self.lib.fs_capture_stop(h);self.assertTrue(frames)
                import base64
                for frame in frames:
                    self.assertEqual(frame['event']['type'],'output' if playback else 'input')
                    self.assertEqual(set(frame['event']),{'type','payload','volume','sampleRate','bufferDurationMs'} if playback else {'type','payload','volume'})
                    if playback:self.assertEqual(len(base64.b64decode(frame['data'])),rate*2*40//1000)
        finally:os.environ['PATH']=old
    def test_capture_device_loss_retries_discard_partial_playback_frame(self):
        import base64
        marker=self.path/'capture-attempt'
        runner=self.path/'pw-record'
        runner.write_text('#!/usr/bin/env python3\nimport os,time,pathlib\np=pathlib.Path('+repr(str(marker))+')\nif not p.exists():\n p.write_text("started")\n os.write(1,b"A"*17)\nelse:\n os.write(1,b"B"*3840)\n time.sleep(60)\n')
        runner.chmod(0o755);old=os.environ['PATH'];os.environ['PATH']=str(self.path)+':'+old
        h=None
        try:
            h=self.lib.fs_capture_start(b'auto',1,48000);events=[];deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                event=owned_json(self.lib,self.lib.fs_event_poll(h,100))
                if event:
                    events.append(event)
                    if event['type']=='pcm':break
            gaps=[event for event in events if event['type']=='gap']
            self.assertEqual(len(gaps),1,events)
            self.assertEqual(gaps[0]['discarded_bytes'],17)
            self.assertEqual(gaps[0]['reason'],'device_or_pipewire_lost')
            self.assertEqual(gaps[0]['exit_status'],0)
            states=[event['state'] for event in events if event['type']=='state']
            self.assertEqual(states,['connecting','capturing','connecting','capturing'])
            frames=[event for event in events if event['type']=='pcm']
            self.assertEqual(len(frames),1,events)
            self.assertEqual(base64.b64decode(frames[0]['data']),b'B'*3840)
            self.assertEqual(base64.b64decode(frames[0]['event']['payload']),b'B'*3840)
        finally:
            if h:self.lib.fs_capture_stop(h)
            os.environ['PATH']=old
    def test_speech_cancel_finish_and_destroy_active_reaps_worker(self):
        marker=self.path/'speech-worker-pid'
        runner=self.runner('import os,time,pathlib\npathlib.Path('+repr(str(marker))+').write_text(str(os.getpid()))\ntime.sleep(60)\n')
        speech=self.lib.fs_speech_create(runner,str(self.model).encode())
        def wait_pid():
            deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                if marker.exists() and marker.read_text():return int(marker.read_text())
                time.sleep(.01)
            self.fail('speech worker did not start')
        try:
            self.assertEqual(self.lib.fs_speech_finish(speech,b'cancel-asr'),0);pid=wait_pid()
            self.assertEqual(self.lib.fs_speech_cancel(speech),0);self.assertEqual(self.lib.fs_speech_cancel(speech),0)
            events=drain(self.lib,speech)
            self.assertEqual([event['type'] for event in events],['done'])
            self.assertEqual(events[0]['status'],'cancelled')
            self.assertIsNone(owned_json(self.lib,self.lib.fs_event_poll(speech,20)))
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)
            marker.unlink();self.assertEqual(self.lib.fs_speech_finish(speech,b'destroy-asr'),0);pid=wait_pid()
            before=time.monotonic();self.lib.fs_speech_destroy(speech);speech=None
            self.assertLess(time.monotonic()-before,1)
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)
        finally:
            if speech:self.lib.fs_speech_destroy(speech)
    def test_speech_finish_context_owned_and_variable_buffer_conversion(self):
        runner=self.runner('import wave,sys\np=sys.argv[sys.argv.index("-f")+1]\nw=wave.open(p)\nassert w.getframerate()==16000 and w.getnchannels()==1\nassert w.getnframes()==1600\nprint("owned transcript")\n')
        s=self.lib.fs_speech_create(runner,str(self.model).encode())
        samples=(C.c_int16*4800)(*([100]*4800))
        # uneven 48k buffers must retain resampling phase and preserve 100ms
        for offset,count in [(0,997),(997,1403),(2400,2400)]:
            ptr=C.cast(C.byref(samples,offset*2),C.POINTER(C.c_int16));self.assertEqual(self.lib.fs_speech_push(s,ptr,count,48000),0)
        self.lib.fs_speech_finish(s,b'asr');events=drain(self.lib,s)
        self.assertEqual(events[-1]['status'],'completed');self.assertEqual(events[0]['text'].strip(),'owned transcript');self.assertEqual(events[0]['end_ms'],100)
        self.lib.fs_speech_destroy(s)

if __name__=='__main__':unittest.main()
