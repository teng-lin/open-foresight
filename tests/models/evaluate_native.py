#!/usr/bin/env python3
"""Opt-in real native inference and capture evaluation; no model downloading.
Use --help for required runtime/model paths. JSON includes output and timings.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import resource
import sys
import time
import wave
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'integration'))
from test_native import load,drain,owned_json

def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--library',required=True);p.add_argument('--generation-runtime',required=True);p.add_argument('--generation-model',required=True);p.add_argument('--speech-runtime',required=True);p.add_argument('--speech-model',required=True);p.add_argument('--wav',required=True);p.add_argument('--output',required=True);a=p.parse_args()
    l=load(a.library);l.fs_engine_probe.argtypes=[C.c_void_p];l.fs_engine_probe.restype=C.c_int
    report={'assets':{k:{'path':str(Path(v).resolve()),'sha256':digest(v)} for k,v in vars(a).items() if k not in ['output']},'backend':'cpu-cli','timestamp_units':'milliseconds','claims':'Fixed evaluation fixtures only; not reference model equivalence or physical meeting acceptance'}
    e=l.fs_engine_create(a.generation_runtime.encode(),a.generation_model.encode());assert e
    start=time.monotonic();assert l.fs_engine_probe(e)==0;report['initialization_seconds']=time.monotonic()-start;c=l.fs_conversation_create(e)
    prompt='<|im_start|>system\nAnswer only from the context. Include the citation [meeting] in your answer.<|im_end|>\n<|im_start|>user\nContext [meeting]: Alice will send the budget draft on Friday. Who will send the draft and when? Cite [meeting].<|im_end|>\n<|im_start|>assistant\n'
    start=time.monotonic();assert l.fs_generate(c,b'quality-eval',prompt.encode())==0;events=drain(l,c,120);answer=''.join(x.get('text','') for x in events)
    report['generation']={'prompt':prompt,'answer':answer,'events':events,'seconds':time.monotonic()-start,'semantic_correct':'alice' in answer.lower() and 'friday' in answer.lower(),'citation_present':'[meeting]' in answer,'terminal':events[-1]['status']}
    assert l.fs_conversation_destroy(c,1)==0;assert l.fs_engine_destroy(e)==0
    with wave.open(a.wav) as w:
        assert w.getnchannels()==1 and w.getsampwidth()==2
        pcm=w.readframes(w.getnframes());rate=w.getframerate()
    samples=(C.c_int16*(len(pcm)//2)).from_buffer_copy(pcm);s=l.fs_speech_create(a.speech_runtime.encode(),a.speech_model.encode());assert s;start=time.monotonic();assert l.fs_speech_push(s,samples,len(samples),rate)==0;assert l.fs_speech_finish(s,b'asr-eval')==0;events=drain(l,s,120)
    transcript=''.join(x.get('text','') for x in events);report['speech']={'transcript':transcript,'events':events,'seconds':time.monotonic()-start,'jfk_phrase_correct':'ask not what your country can do for you' in transcript.lower(),'terminal':events[-1]['status']};l.fs_speech_destroy(s)
    report['child_peak_rss_kib']=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='assets'},indent=2))
    assert report['generation']['semantic_correct'] and report['generation']['citation_present'];assert report['speech']['jfk_phrase_correct']
if __name__=='__main__':main()
