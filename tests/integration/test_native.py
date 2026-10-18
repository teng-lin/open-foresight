#!/usr/bin/env python3
"""Native ownership/lifecycle tests. Deterministic runners test control flow only.
Run: python3 tests/integration/test_native.py /path/libforesight_native.so
"""

import ctypes as C
import json
import math
import os
import signal
import threading
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import sys

LIBRARY = (
    sys.argv.pop(1)
    if len(sys.argv) > 1 and sys.argv[1].endswith((".so", ".dylib"))
    else os.environ.get(
        "FORESIGHT_NATIVE_LIBRARY",
        "build/native/libforesight_native"
        + (".dylib" if sys.platform == "darwin" else ".so"),
    )
)


def load(path=LIBRARY):
    lib = C.CDLL(path)
    for name, args, ret in [
        ("fs_set_runtime_environment", [C.c_char_p, C.c_char_p], C.c_int),
        ("fs_engine_create", [C.c_char_p, C.c_char_p], C.c_void_p),
        ("fs_engine_create_backend", [C.c_char_p, C.c_char_p, C.c_int], C.c_void_p),
        ("fs_engine_state", [C.c_void_p], C.c_void_p),
        ("fs_engine_probe", [C.c_void_p], C.c_int),
        ("fs_engine_destroy", [C.c_void_p], C.c_int),
        ("fs_conversation_create", [C.c_void_p], C.c_void_p),
        ("fs_generate", [C.c_void_p, C.c_char_p, C.c_char_p], C.c_int),
        (
            "fs_generate_tools",
            [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_int],
            C.c_int,
        ),
        ("fs_generation_tool_reply", [C.c_void_p, C.c_char_p, C.c_char_p], C.c_int),
        ("fs_generation_cancel", [C.c_void_p], C.c_int),
        ("fs_conversation_destroy", [C.c_void_p, C.c_int], C.c_int),
        ("fs_speech_create", [C.c_char_p, C.c_char_p], C.c_void_p),
        (
            "fs_speech_push",
            [C.c_void_p, C.POINTER(C.c_int16), C.c_size_t, C.c_int],
            C.c_int,
        ),
        ("fs_speech_finish", [C.c_void_p, C.c_char_p], C.c_int),
        ("fs_speech_destroy", [C.c_void_p], None),
        ("fs_speech_cancel", [C.c_void_p], C.c_int),
        ("fs_capture_start", [C.c_char_p, C.c_int, C.c_int], C.c_void_p),
        ("fs_capture_finish", [C.c_void_p], None),
        ("fs_capture_stop", [C.c_void_p], None),
        ("fs_audio_capabilities", [], C.c_void_p),
        ("fs_audio_request_system", [C.c_int32], C.c_void_p),
        ("fs_event_poll", [C.c_void_p, C.c_int], C.c_void_p),
        ("fs_string_free", [C.c_void_p], None),
        ("fs_pcm_rms", [C.POINTER(C.c_int16), C.c_size_t], C.c_double),
        (
            "fs_resample_pcm",
            [
                C.POINTER(C.c_int16),
                C.c_size_t,
                C.c_int,
                C.POINTER(C.c_int16),
                C.c_size_t,
                C.c_int,
            ],
            C.c_size_t,
        ),
    ]:
        fn = getattr(lib, name)
        fn.argtypes = args
        fn.restype = ret
    return lib


def owned_json(lib, pointer):
    if not pointer:
        return None
    try:
        return json.loads(C.string_at(pointer))
    finally:
        lib.fs_string_free(pointer)


def drain(lib, handle, timeout=10):
    output = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        item = owned_json(lib, lib.fs_event_poll(handle, 100))
        if item:
            output.append(item)
            if item["type"] == "done":
                return output
    raise TimeoutError(output)


class NativeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load()

    @unittest.skipUnless(sys.platform == "darwin", "macOS permission contract")
    def test_macos_capture_permission_failure_and_finish_retains_events(self):
        capabilities = owned_json(self.lib, self.lib.fs_audio_capabilities())
        self.assertEqual(capabilities["backend"], "core_audio_tap")
        self.assertEqual(capabilities["system_audio"], "unknown")
        self.assertEqual(capabilities["system_audio_request"], "not_requested")
        self.assertFalse(capabilities["permission_verified"])
        if not capabilities["system_audio_purpose_present"]:
            result = owned_json(self.lib, self.lib.fs_audio_request_system(0))
            self.assertEqual(result["code"], "capture_bundle_misconfigured")
            self.assertFalse(result["permission_verified"])
        if capabilities["microphone"] == "authorized":
            self.skipTest(
                "Microphone already granted; do not open a physical recording in CI"
            )
        handle = self.lib.fs_capture_start(b"auto", 0, 48000)
        self.assertTrue(handle)
        try:
            deadline = time.monotonic() + 2
            events = []
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
                if event:
                    events.append(event)
                    if event.get("state") == "failed":
                        break
            self.assertTrue(
                any(
                    event.get("code") == "microphone_permission_required"
                    for event in events
                ),
                events,
            )
            self.lib.fs_capture_finish(handle)
            # finish joins but keeps the final lifecycle event available to poll.
            final = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
            self.assertEqual(final["state"], "stopped")
        finally:
            self.lib.fs_capture_stop(handle)
        self.assertEqual(
            owned_json(self.lib, self.lib.fs_audio_capabilities())["microphone"],
            capabilities["microphone"],
        )

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)
        self.model = self.path / "asset"
        self.model.write_text("test only")

    def tearDown(self):
        self.directory.cleanup()

    def runner(self, body):
        runner = self.path / "runner"
        runner.write_text("#!/usr/bin/env python3\n" + body)
        runner.chmod(0o755)
        return str(runner).encode()

    def engine(self, body):
        return self.lib.fs_engine_create(self.runner(body), str(self.model).encode())

    def test_runtime_environment_is_sealed_by_the_first_handle(self):
        engine = self.engine("pass\n")
        try:
            self.assertEqual(
                self.lib.fs_set_runtime_environment(
                    b"FORESIGHT_LITERT_BACKEND", b"gpu"
                ),
                -1,
            )
        finally:
            self.lib.fs_engine_destroy(engine)
        self.assertEqual(
            self.lib.fs_set_runtime_environment(b"FORESIGHT_LITERT_BACKEND", b"gpu"), -1
        )

    def test_destroy_wakes_and_joins_a_blocking_poll(self):
        speech = self.lib.fs_speech_create(
            self.runner("pass\n"), str(self.model).encode()
        )
        entered = threading.Event()
        result = []

        def poll():
            entered.set()
            result.append(self.lib.fs_event_poll(speech, 60000))

        thread = threading.Thread(target=poll)
        thread.start()
        self.assertTrue(entered.wait(2))
        before = time.monotonic()
        self.lib.fs_speech_destroy(speech)
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertLess(time.monotonic() - before, 2)
        self.assertEqual(result, [None])
        self.assertIsNone(self.lib.fs_event_poll(speech, 0))

    def test_destroy_refuses_a_live_engine_probe(self):
        ready = self.path / "probe-ready"
        release = self.path / "probe-release"
        body = (
            "import pathlib,time\npathlib.Path("
            + repr(str(ready))
            + ").touch()\nwhile not pathlib.Path("
            + repr(str(release))
            + ").exists():time.sleep(.005)\n"
        )
        engine = self.engine(body)
        result = []
        probe = threading.Thread(
            target=lambda: result.append(self.lib.fs_engine_probe(engine))
        )
        probe.start()
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                threading.Event().wait(0.005)
            self.assertTrue(ready.exists())
            self.assertEqual(self.lib.fs_engine_destroy(engine), -1)
        finally:
            release.touch()
            probe.join(timeout=3)
        self.assertFalse(probe.is_alive())
        self.assertEqual(result, [0])
        self.assertEqual(self.lib.fs_engine_destroy(engine), 0)

    def test_generation_and_speech_replace_invalid_utf8(self):
        runner = self.runner('import os\nos.write(1,b"good\\xffbad\\xed\\xa0\\x80")\n')
        engine = self.lib.fs_engine_create(runner, str(self.model).encode())
        conversation = self.lib.fs_conversation_create(engine)
        speech = self.lib.fs_speech_create(runner, str(self.model).encode())
        try:
            self.assertEqual(self.lib.fs_generate(conversation, b"utf8", b"prompt"), 0)
            events = drain(self.lib, conversation)
            self.assertIn("good\ufffdbad", "".join(e.get("text", "") for e in events))
            self.assertEqual(events[-1]["status"], "completed")
            samples = (C.c_int16 * 1600)(*([100] * 1600))
            self.lib.fs_speech_push(speech, samples, len(samples), 16000)
            self.lib.fs_speech_finish(speech, b"utf8-speech")
            events = drain(self.lib, speech)
            self.assertIn(
                "good\ufffdbad",
                next(e["text"] for e in events if e["type"] == "transcript"),
            )
        finally:
            self.lib.fs_conversation_destroy(conversation, 1)
            self.lib.fs_engine_destroy(engine)
            self.lib.fs_speech_destroy(speech)

    def test_tool_payloads_reject_newlines_before_changing_request_state(self):
        engine = self.lib.fs_engine_create_backend(
            self.runner(
                "import sys\nprint('tool []',flush=True)\nsys.stdin.readline()\nprint('answer {}',flush=True)\n"
            ),
            str(self.model).encode(),
            1,
        )
        handle = self.lib.fs_conversation_create(engine)
        try:
            self.assertEqual(
                self.lib.fs_generate_tools(handle, b"framed", b"q", b"[\n{}]", 256), -1
            )
            self.assertEqual(
                self.lib.fs_generate_tools(handle, b"framed", b"q", b"[{}]", 256), 0
            )
            request = owned_json(self.lib, self.lib.fs_event_poll(handle, 5000))
            self.assertEqual(request["type"], "tool_request")
            self.assertEqual(
                self.lib.fs_generation_tool_reply(handle, b"framed", b"{}\n{}"), -1
            )
            self.assertEqual(
                self.lib.fs_generation_tool_reply(handle, b"framed", b"{}"), 0
            )
            self.assertEqual(drain(self.lib, handle)[-1]["status"], "completed")
        finally:
            self.lib.fs_conversation_destroy(handle, 1)
            self.lib.fs_engine_destroy(engine)

    def test_tool_round_trip_large_unicode_and_scoped_single_reply(self):
        body = """import json,sys
assert '--tools' in sys.argv
print('tool '+json.dumps([{'function': {'name':'google_search','arguments':{'query':'q'}}}]), flush=True)
reply=json.loads(sys.stdin.readline())
assert reply['role']=='user'
assert reply['content'][0]['text']=='🧪'*25000
print('answer '+json.dumps({'role':'assistant','content':[{'type':'text','text':'Answer [Source:1]'}]}), flush=True)
"""
        engine = self.lib.fs_engine_create_backend(
            self.runner(body), str(self.model).encode(), 1
        )
        handle = self.lib.fs_conversation_create(engine)
        try:
            self.assertEqual(
                self.lib.fs_generate_tools(
                    handle, b"tool-owner", b"q", b'[{"name":"google_search"}]', 256
                ),
                0,
            )
            request = owned_json(self.lib, self.lib.fs_event_poll(handle, 5000))
            self.assertEqual(request["type"], "tool_request", request)
            self.assertEqual(
                json.loads(request["text"])[0]["function"]["name"], "google_search"
            )
            reply = json.dumps(
                {"role": "user", "content": [{"type": "text", "text": "🧪" * 25000}]},
                ensure_ascii=False,
            ).encode()
            self.assertNotEqual(
                self.lib.fs_generation_tool_reply(handle, b"other-owner", reply), 0
            )
            self.assertEqual(
                self.lib.fs_generation_tool_reply(handle, b"tool-owner", reply), 0
            )
            self.assertNotEqual(
                self.lib.fs_generation_tool_reply(handle, b"tool-owner", reply), 0
            )
            events = [request] + drain(self.lib, handle)
            self.assertEqual(events[-1]["status"], "completed", events)
            self.assertEqual([e["sequence"] for e in events], list(range(len(events))))
            answer = next(e for e in events if e["type"] == "tool_answer")
            self.assertEqual(
                json.loads(answer["text"])["content"][0]["text"], "Answer [Source:1]"
            )
            self.assertNotEqual(
                self.lib.fs_generation_tool_reply(handle, b"tool-owner", reply), 0
            )
        finally:
            self.lib.fs_conversation_destroy(handle, 1)
            self.lib.fs_engine_destroy(engine)

    def test_tool_wait_cancellation_rejects_late_reply(self):
        runner = self.runner(
            "import sys\nprint('tool []',flush=True)\nsys.stdin.readline()\n"
        )
        engine = self.lib.fs_engine_create_backend(runner, str(self.model).encode(), 1)
        handle = self.lib.fs_conversation_create(engine)
        try:
            self.assertEqual(
                self.lib.fs_generate_tools(handle, b"cancel-tool", b"q", b"[{}]", 256),
                0,
            )
            request = owned_json(self.lib, self.lib.fs_event_poll(handle, 5000))
            self.assertEqual(request["type"], "tool_request", request)
            self.assertEqual(self.lib.fs_generation_cancel(handle), 0)
            self.assertNotEqual(
                self.lib.fs_generation_tool_reply(handle, b"cancel-tool", b"{}"), 0
            )
            events = drain(self.lib, handle)
            self.assertEqual(events[-1]["status"], "cancelled", events)
        finally:
            self.lib.fs_conversation_destroy(handle, 1)
            self.lib.fs_engine_destroy(engine)

    def test_tool_worker_cannot_publish_success_without_a_complete_answer(self):
        for body in [
            "pass\n",
            "print('invalid protocol',flush=True)\n",
            "print('answer {',end='',flush=True)\n",
        ]:
            engine = self.lib.fs_engine_create_backend(
                self.runner(body), str(self.model).encode(), 1
            )
            handle = self.lib.fs_conversation_create(engine)
            try:
                self.assertEqual(
                    self.lib.fs_generate_tools(
                        handle, b"bad-worker", b"q", b"[{}]", 256
                    ),
                    0,
                )
                events = drain(self.lib, handle)
                self.assertEqual(events[-1]["status"], "failed", events)
                self.assertTrue(any(e["type"] == "error" for e in events), events)
            finally:
                self.lib.fs_conversation_destroy(handle, 1)
                self.lib.fs_engine_destroy(engine)

    def test_speech_retries_cpu_once_without_failed_attempt_text(self):
        log = self.path / "speech-attempts"
        runner = self.runner(
            "import pathlib,sys\np=pathlib.Path("
            + repr(str(log))
            + ')\nwith p.open("a") as f: f.write("cpu\\n" if "-ng" in sys.argv else "gpu\\n")\nif "-ng" not in sys.argv: print("uncommitted GPU junk");sys.exit(7)\nassert "-dev" not in sys.argv\nprint("CPU transcript")\n'
        )
        with patch.dict(
            os.environ,
            {
                "FORESIGHT_WHISPER_BACKEND": "gpu",
                "FORESIGHT_WHISPER_DEVICE": "1",
                "FORESIGHT_WHISPER_RUNTIME": "",
            },
        ):
            speech = self.lib.fs_speech_create(runner, str(self.model).encode())
            try:
                samples = (C.c_int16 * 1600)(*([100] * 1600))
                self.lib.fs_speech_push(speech, samples, len(samples), 16000)
                self.lib.fs_speech_finish(speech, b"cpu-retry")
                events = drain(self.lib, speech)
                self.assertEqual(events[-1]["status"], "completed", events)
                self.assertEqual(
                    next(e["text"] for e in events if e["type"] == "transcript"),
                    "CPU transcript\n",
                )
                self.assertEqual(log.read_text().splitlines(), ["gpu", "cpu"])
            finally:
                self.lib.fs_speech_destroy(speech)

    def test_persistent_gpu_failure_rebuilds_retained_cpu_worker(self):
        attempts = self.path / "persistent-attempts"
        runner = self.runner(
            """import json,pathlib,sys
log=pathlib.Path("""
            + repr(str(attempts))
            + """)
cpu='--backend' in sys.argv and sys.argv[sys.argv.index('--backend')+1]=='cpu'
def record(value):
 with log.open('a') as f:f.write(value+'\\n')
if '--probe' in sys.argv:
 print(json.dumps({'worker_protocol':1}),flush=True)
else:
 record('cpu serve' if cpu else 'gpu serve')
 print('ready 1',flush=True)
 for line in sys.stdin:
  if line.strip()=='shutdown':break
  operation,token,payload=line.strip().split(' ',2)
  if operation=='generate':
   record('cpu generate' if cpu else 'gpu generate')
   if cpu:
    print(token+' answer '+json.dumps({'role':'assistant','content':'CPU answer'}),flush=True)
    print(token+' done completed',flush=True)
   else:
    print(token+' delta '+json.dumps({'content':'partial GPU preview'}),flush=True)
    print(token+' error '+json.dumps('GPU device lost'),flush=True)
    print(token+' done failed',flush=True)
"""
        )
        with patch.dict(os.environ, {"FORESIGHT_LITERT_BACKEND": "gpu"}):
            engine = self.lib.fs_engine_create_backend(
                runner, str(self.model).encode(), 1
            )
            handle = None
            try:
                self.assertEqual(self.lib.fs_engine_probe(engine), 0)
                handle = self.lib.fs_conversation_create(engine)
                self.assertEqual(
                    self.lib.fs_generate_tools(
                        handle, b"failed-gpu", b"q", b"[{}]", 64
                    ),
                    0,
                )
                failed = drain(self.lib, handle)
                self.assertEqual(failed[-1]["status"], "failed", failed)
                self.assertTrue(any(e.get("backend") == "cpu" for e in failed), failed)
                self.assertEqual(
                    attempts.read_text().splitlines(),
                    ["gpu serve", "gpu generate", "cpu serve"],
                )
                self.lib.fs_conversation_destroy(handle, 1)
                handle = self.lib.fs_conversation_create(engine)
                self.assertEqual(
                    self.lib.fs_generate_tools(
                        handle, b"recovered-cpu", b"q", b"[{}]", 64
                    ),
                    0,
                )
                completed = drain(self.lib, handle)
                self.assertEqual(completed[-1]["status"], "completed", completed)
                self.assertIn(
                    "CPU answer",
                    next(e["text"] for e in completed if e["type"] == "tool_answer"),
                )
                self.assertEqual(
                    attempts.read_text().splitlines(),
                    ["gpu serve", "gpu generate", "cpu serve", "cpu generate"],
                )
            finally:
                if handle:
                    self.lib.fs_conversation_destroy(handle, 1)
                self.lib.fs_engine_destroy(engine)

    def test_gpu_generation_failure_rebuilds_cpu_without_replaying_request(self):
        attempts = self.path / "generation-attempts"
        runner = self.runner(
            "import pathlib,sys\np=pathlib.Path("
            + repr(str(attempts))
            + ')\ncpu="--backend" in sys.argv and sys.argv[sys.argv.index("--backend")+1]=="cpu"\nwith p.open("a") as f:f.write(("cpu" if cpu else "gpu")+(" probe\\n" if "--probe" in sys.argv else " generate\\n"))\nif "--probe" in sys.argv:sys.exit(0)\nif not cpu:print("partial GPU output");sys.exit(9)\nprint("Recovered CPU answer")\n'
        )
        with patch.dict(os.environ, {"FORESIGHT_LITERT_BACKEND": "gpu"}):
            engine = self.lib.fs_engine_create_backend(
                runner, str(self.model).encode(), 1
            )
            handle = self.lib.fs_conversation_create(engine)
            try:
                self.lib.fs_generate(handle, b"gpu-failure", b"q")
                failed = drain(self.lib, handle)
                self.assertEqual(failed[-1]["status"], "failed")
                self.assertTrue(any(e.get("backend") == "cpu" for e in failed), failed)
                self.assertEqual(
                    attempts.read_text().splitlines(), ["gpu generate", "cpu probe"]
                )
                state = owned_json(self.lib, self.lib.fs_engine_state(engine))
                self.assertEqual(state["state"], "ready")
                self.assertEqual(state["backend"], "litert-lm-cpu-native")
                self.lib.fs_conversation_destroy(handle, 1)
                handle = self.lib.fs_conversation_create(engine)
                self.lib.fs_generate(handle, b"cpu-answer", b"q")
                done = drain(self.lib, handle)
                self.assertEqual(done[-1]["status"], "completed")
                self.assertIn(
                    "Recovered CPU answer",
                    "".join(e.get("text", "") for e in done if e["type"] == "delta"),
                )
            finally:
                self.lib.fs_conversation_destroy(handle, 1)
                self.lib.fs_engine_destroy(engine)

    def test_full_capture_queue_emits_real_overflow_gap(self):
        ready = self.path / "capture-queue-filled"
        runner = self.runner(
            'import os,pathlib,time\nfor _ in range(600):os.write(1,b"A"*3840)\n'
            + "pathlib.Path("
            + repr(str(ready))
            + ").touch()\ntime.sleep(30)\n"
        ).decode()
        with patch.dict(os.environ, {"FORESIGHT_CAPTURE_RUNTIME": runner}):
            handle = self.lib.fs_capture_start(b"auto", 0, 48000)
            try:
                # Completed writes exceed both the pipe and native queue capacity.
                # Keep events queued until the producer confirms those writes.
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    threading.Event().wait(0.005)
                self.assertTrue(
                    ready.exists(), "capture producer did not fill the queue"
                )
                self.lib.fs_capture_finish(handle)
                events = []
                while True:
                    value = owned_json(self.lib, self.lib.fs_event_poll(handle, 0))
                    if value is None:
                        break
                    events.append(value)
                gaps = [
                    e for e in events if e.get("reason") == "capture_buffer_overflow"
                ]
                self.assertTrue(gaps, events[-5:])
                self.assertGreater(sum(e["discarded_bytes"] for e in gaps), 0)
                self.assertLessEqual(sum(e["type"] == "pcm" for e in events), 256)
            finally:
                self.lib.fs_capture_stop(handle)

    def test_speech_runtime_override_and_explicit_cpu(self):
        runner = self.runner(
            'import sys\nassert "-ng" in sys.argv\nprint("GPU runtime CPU override")\n'
        ).decode()
        with patch.dict(
            os.environ,
            {"FORESIGHT_WHISPER_RUNTIME": runner, "FORESIGHT_WHISPER_BACKEND": "cpu"},
        ):
            speech = self.lib.fs_speech_create(
                b"/missing/registered-runner", str(self.model).encode()
            )
            try:
                samples = (C.c_int16 * 1600)(*([100] * 1600))
                self.assertEqual(
                    self.lib.fs_speech_push(speech, samples, len(samples), 16000), 0
                )
                self.assertEqual(self.lib.fs_speech_finish(speech, b"override"), 0)
                events = drain(self.lib, speech)
                self.assertEqual(events[-1]["status"], "completed")
                self.assertIn(
                    "GPU runtime CPU override",
                    next(e["text"] for e in events if e["type"] == "transcript"),
                )
            finally:
                self.lib.fs_speech_destroy(speech)

    def test_speech_detects_language_without_translation_and_preserves_gpu_device(self):
        runner = self.runner(
            'import sys\nassert sys.argv[sys.argv.index("-l") + 1] == "auto"\nassert "-tr" not in sys.argv and "--translate" not in sys.argv\nassert sys.argv[sys.argv.index("-dev") + 1] == "1"\nprint("你好，please review the target product profile。")\n'
        )
        with patch.dict(
            os.environ,
            {
                "FORESIGHT_WHISPER_RUNTIME": "",
                "FORESIGHT_WHISPER_BACKEND": "gpu",
                "FORESIGHT_WHISPER_DEVICE": "1",
            },
        ):
            speech = self.lib.fs_speech_create(runner, str(self.model).encode())
            try:
                samples = (C.c_int16 * 1600)(*([100] * 1600))
                self.assertEqual(
                    self.lib.fs_speech_push(speech, samples, len(samples), 16000), 0
                )
                self.assertEqual(self.lib.fs_speech_finish(speech, b"multilingual"), 0)
                events = drain(self.lib, speech)
                self.assertEqual(events[-1]["status"], "completed")
                self.assertIn(
                    "你好，please review",
                    next(e["text"] for e in events if e["type"] == "transcript"),
                )
            finally:
                self.lib.fs_speech_destroy(speech)

    def test_delta_order_terminal_reference_and_uniqueness(self):
        e = self.engine(
            'import os,time\nos.write(1,b"hello ")\ntime.sleep(.05)\nos.write(1,"世界".encode())\n'
        )
        c = self.lib.fs_conversation_create(e)
        self.assertEqual(self.lib.fs_engine_destroy(e), -1)
        self.assertEqual(self.lib.fs_generate(c, b"r1", b"prompt"), 0)
        items = drain(self.lib, c)
        self.assertEqual(
            "".join(x["text"] for x in items if x["type"] == "delta"), "hello 世界"
        )
        self.assertEqual([x["sequence"] for x in items], list(range(len(items))))
        self.assertEqual(items[-1]["status"], "completed")
        self.assertIsNone(owned_json(self.lib, self.lib.fs_event_poll(c, 20)))
        self.assertEqual(self.lib.fs_generate(c, b"r1", b"prompt"), -1)
        self.assertEqual(self.lib.fs_conversation_destroy(c, 1), 0)
        self.assertEqual(self.lib.fs_engine_destroy(e), 0)

    def test_busy_cancel_free_and_no_child_after_release(self):
        e = self.engine("import time\ntime.sleep(60)\n")
        a = self.lib.fs_conversation_create(e)
        b = self.lib.fs_conversation_create(e)
        self.assertEqual(self.lib.fs_generate(a, b"slow", b"x"), 0)
        self.assertEqual(self.lib.fs_generate(b, b"busy", b"x"), -1)
        self.assertEqual(self.lib.fs_conversation_destroy(a, 0), -1)
        self.lib.fs_generation_cancel(a)
        self.lib.fs_generation_cancel(a)
        self.assertEqual(drain(self.lib, a)[-1]["status"], "cancelled")
        before = time.monotonic()
        self.lib.fs_conversation_destroy(a, 1)
        self.assertLess(time.monotonic() - before, 1)
        self.lib.fs_conversation_destroy(b, 1)
        self.lib.fs_engine_destroy(e)

    @unittest.skipUnless(
        sys.platform in ("linux", "darwin"), "POSIX child reaping regression"
    )
    def test_probe_never_reports_success_when_child_exit_status_is_lost(self):
        runner = self.runner(
            "import json,sys\nprint(json.dumps({'worker_protocol':1,'native_stop_token_sequences':True}),flush=True)\nsys.exit(7)\n"
        )
        for ignored in (False, True):
            with self.subTest(sigchld_ignored=ignored):
                engine = self.lib.fs_engine_create_backend(
                    runner, str(self.model).encode(), 1
                )
                previous = signal.getsignal(signal.SIGCHLD)
                try:
                    if ignored:
                        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
                    self.assertEqual(self.lib.fs_engine_probe(engine), -1)
                    state = owned_json(self.lib, self.lib.fs_engine_state(engine))
                    self.assertEqual(state["state"], "failed")
                    self.assertFalse(state["native_stop_token_sequences"])
                    self.assertIn("Model initialization probe failed", state["error"])
                finally:
                    signal.signal(signal.SIGCHLD, previous)
                    self.lib.fs_engine_destroy(engine)

    @unittest.skipUnless(
        sys.platform in ("linux", "darwin"), "POSIX host reaper regression"
    )
    def test_probe_retains_actual_status_with_host_child_reaper(self):
        import threading

        stop = threading.Event()

        def reap():
            while not stop.is_set():
                try:
                    os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    pass
                stop.wait(0.0005)

        for ignored in (False, True):
            previous = signal.getsignal(signal.SIGCHLD)
            if ignored:
                signal.signal(signal.SIGCHLD, signal.SIG_IGN)
            reaper = threading.Thread(target=reap)
            reaper.start()
            try:
                for status in (0, 7, 0, 7, 0, 7):
                    with self.subTest(sigchld_ignored=ignored, status=status):
                        runner = self.runner(
                            "import json,sys\nprint(json.dumps({'worker_protocol':1,'native_stop_token_sequences':True}),flush=True)\nsys.exit(%d)\n"
                            % status
                        )
                        engine = self.lib.fs_engine_create_backend(
                            runner, str(self.model).encode(), 1
                        )
                        try:
                            self.assertEqual(
                                self.lib.fs_engine_probe(engine),
                                0 if status == 0 else -1,
                            )
                            state = owned_json(
                                self.lib, self.lib.fs_engine_state(engine)
                            )
                            self.assertEqual(
                                state["state"], "ready" if status == 0 else "failed"
                            )
                            self.assertEqual(
                                state["native_stop_token_sequences"], status == 0
                            )
                            if status:
                                self.assertIn("status 7", state["error"])
                        finally:
                            self.lib.fs_engine_destroy(engine)
            finally:
                stop.set()
                reaper.join()
                stop.clear()
                signal.signal(signal.SIGCHLD, previous)

    def test_failed_start_error_before_single_terminal(self):
        e = self.lib.fs_engine_create(
            b"/missing/foresight-runtime", str(self.model).encode()
        )
        self.assertEqual(
            owned_json(self.lib, self.lib.fs_engine_state(e))["state"], "configured"
        )
        self.assertEqual(self.lib.fs_engine_probe(e), -1)
        self.assertEqual(
            owned_json(self.lib, self.lib.fs_engine_state(e))["state"], "failed"
        )
        c = self.lib.fs_conversation_create(e)
        self.lib.fs_generate(c, b"failure", b"prompt")
        events = drain(self.lib, c)
        self.assertEqual([e["type"] for e in events], ["error", "done"])
        self.assertEqual(events[-1]["status"], "failed")
        self.lib.fs_conversation_destroy(c, 1)
        self.lib.fs_engine_destroy(e)

    def test_audio_rms_and_conversion(self):
        samples = (C.c_int16 * 4)(32767, -32767, 0, 0)
        self.assertAlmostEqual(
            self.lib.fs_pcm_rms(samples, 4), math.sqrt(0.5), places=10
        )
        extreme = (C.c_int16 * 1)(-32768)
        self.assertGreater(self.lib.fs_pcm_rms(extreme, 1), 1)
        inp = (C.c_int16 * 6)(0, 1000, 2000, 3000, 4000, 5000)
        out = (C.c_int16 * 3)()
        self.assertEqual(self.lib.fs_resample_pcm(inp, 6, 48000, out, 3, 24000), 3)
        self.assertEqual(list(out), [0, 2000, 4000])

    def test_capture_fixed_playback_frames_and_legacy_microphone_map(self):
        runner = self.path / "pw-record"
        runner.write_text(
            '#!/usr/bin/env python3\nimport os,time,sys\nassert "--raw" not in sys.argv\nassert sys.argv[-1] == "-"\ntarget=sys.argv[sys.argv.index("--target")+1]\nif target != "auto":\n props=sys.argv[sys.argv.index("--properties")+1]\n assert "node.dont-fallback = true" in props\n assert "node.dont-reconnect = true" in props\nfor n in [1,500,4000,3219]:\n os.write(1,b"\\0"*n);time.sleep(.02)\ntime.sleep(60)\n'
        )
        runner.chmod(0o755)
        override = patch.dict(os.environ, {"FORESIGHT_CAPTURE_RUNTIME": str(runner)})
        override.start()
        old = os.environ["PATH"]
        os.environ["PATH"] = str(self.path) + ":" + old
        try:
            for playback, rate, target in [
                (0, 48000, b"auto"),
                (1, 48000, b"auto"),
                (1, 16000, b"auto"),
                (1, 11013, b"auto"),
                (0, 48000, b"selected-microphone"),
                (1, 48000, b"selected-playback"),
            ]:
                h = self.lib.fs_capture_start(target, playback, rate)
                frames = []
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    event = owned_json(self.lib, self.lib.fs_event_poll(h, 100))
                    if event and event["type"] == "pcm":
                        frames.append(event)
                        if (playback and len(frames) == 2) or (
                            not playback and len(frames) == 3
                        ):
                            break
                self.lib.fs_capture_stop(h)
                self.assertTrue(frames)
                import base64

                for frame in frames:
                    self.assertEqual(
                        frame["event"]["type"], "output" if playback else "input"
                    )
                    self.assertEqual(
                        set(frame["event"]),
                        {"type", "payload", "volume", "sampleRate", "bufferDurationMs"}
                        if playback
                        else {"type", "payload", "volume"},
                    )
                    if playback:
                        self.assertEqual(
                            len(base64.b64decode(frame["data"])),
                            (rate * 40 // 1000) * 2,
                        )
        finally:
            os.environ["PATH"] = old
            override.stop()

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "production PipeWire adapter"
    )
    def test_capture_raw_fifo_excludes_stdout_diagnostics_and_cleans_up(self):
        import base64

        marker = self.path / "fifo-path"
        runner = self.path / "pw-record"
        runner.write_text(
            "#!/usr/bin/env python3\n"
            + "import os,pathlib,stat,sys\n"
            + 'assert "--raw" not in sys.argv\n'
            + "p=pathlib.Path(sys.argv[-1])\n"
            + 'assert p.suffix == ".raw" and stat.S_ISFIFO(p.stat().st_mode)\n'
            + "assert stat.S_IMODE(p.stat().st_mode) == 0o600\n"
            + "assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700\n"
            + "pathlib.Path("
            + repr(str(marker))
            + ").write_text(str(p))\n"
            + 'print("stream node 42 error: target not found",flush=True)\n'
            + 'with p.open("wb",buffering=0) as output: output.write(b"A"*3840)\n'
            + 'print("stream node 42 unconnected",flush=True)\n'
        )
        runner.chmod(0o755)
        environment = patch.dict(
            os.environ,
            {
                "FORESIGHT_CAPTURE_RUNTIME": "",
                "PATH": str(self.path) + ":" + os.environ["PATH"],
            },
        )
        environment.start()
        handle = self.lib.fs_capture_start(b"missing-selected-target", 1, 48000)
        self.assertTrue(handle)
        try:
            events = []
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
                if event:
                    events.append(event)
                    if event["type"] == "gap":
                        break
            self.assertTrue(any(e["type"] == "gap" for e in events), events)
            self.assertEqual(
                [base64.b64decode(e["data"]) for e in events if e["type"] == "pcm"],
                [b"A" * 3840],
                events,
            )
            path = Path(marker.read_text())
            self.assertFalse(path.exists())
            self.assertFalse(path.parent.exists())
        finally:
            self.lib.fs_capture_stop(handle)
            environment.stop()

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "production PipeWire adapter"
    )
    def test_capture_raw_fifo_child_exit_without_open_is_observed(self):
        import signal

        previous = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        runner = self.path / "pw-record"
        runner.write_text(
            '#!/usr/bin/env python3\nprint("stream node 42 error: target not found",flush=True)\n'
        )
        runner.chmod(0o755)
        environment = patch.dict(
            os.environ,
            {
                "FORESIGHT_CAPTURE_RUNTIME": "",
                "PATH": str(self.path) + ":" + os.environ["PATH"],
            },
        )
        environment.start()
        handle = self.lib.fs_capture_start(b"missing-selected-target", 0, 48000)
        try:
            events = []
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
                if event:
                    events.append(event)
                    if event["type"] == "gap":
                        break
            self.assertTrue(any(e["type"] == "gap" for e in events), events)
            self.assertFalse(
                any(
                    e["type"] == "pcm" or e.get("state") == "capturing" for e in events
                ),
                events,
            )
            self.assertEqual(events[-1]["exit_status"], 0)
        finally:
            self.lib.fs_capture_stop(handle)
            environment.stop()
            signal.signal(signal.SIGCHLD, previous)

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "production PipeWire adapter"
    )
    def test_capture_raw_fifo_finish_preserves_partial_final_frame(self):
        import base64

        runner = self.path / "pw-record"
        runner.write_text(
            "#!/usr/bin/env python3\nimport pathlib,sys,time\n"
            + 'with pathlib.Path(sys.argv[-1]).open("wb",buffering=0) as output: output.write(b"A"*3858)\n'
            + "time.sleep(60)\n"
        )
        runner.chmod(0o755)
        environment = patch.dict(
            os.environ,
            {
                "FORESIGHT_CAPTURE_RUNTIME": "",
                "PATH": str(self.path) + ":" + os.environ["PATH"],
            },
        )
        environment.start()
        handle = self.lib.fs_capture_start(b"selected-target", 1, 48000)
        try:
            events = []
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
                if event:
                    events.append(event)
                    if event["type"] == "pcm":
                        break
            self.assertTrue(any(e["type"] == "pcm" for e in events), events)
            self.lib.fs_capture_finish(handle)
            while True:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 0))
                if not event:
                    break
                events.append(event)
            self.assertEqual(
                [
                    len(base64.b64decode(e["data"]))
                    for e in events
                    if e["type"] == "pcm"
                ],
                [3840, 18],
            )
            self.assertEqual(events[-1]["state"], "stopped")
        finally:
            self.lib.fs_capture_stop(handle)
            environment.stop()

    def test_capture_finish_preserves_partial_final_frame(self):
        import base64

        runner = self.path / "capture-tail"
        runner.write_text(
            '#!/usr/bin/env python3\nimport os,time\nos.write(1,b"A"*18)\ntime.sleep(60)\n'
        )
        runner.chmod(0o755)
        with patch.dict(os.environ, {"FORESIGHT_CAPTURE_RUNTIME": str(runner)}):
            handle = self.lib.fs_capture_start(b"auto", 1, 48000)
        self.assertTrue(handle)
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 100))
                if event and event.get("state") == "capturing":
                    break
            else:
                self.fail("capture fixture did not start")
            self.lib.fs_capture_finish(handle)
            events = []
            while True:
                event = owned_json(self.lib, self.lib.fs_event_poll(handle, 0))
                if not event:
                    break
                events.append(event)
            frames = [event for event in events if event["type"] == "pcm"]
            self.assertEqual(
                [base64.b64decode(frame["data"]) for frame in frames], [b"A" * 18]
            )
            self.assertEqual(events[-1]["state"], "stopped")
        finally:
            self.lib.fs_capture_stop(handle)

    def test_capture_device_loss_retries_discard_partial_playback_frame(self):
        import base64

        marker = self.path / "capture-attempt"
        runner = self.path / "pw-record"
        runner.write_text(
            "#!/usr/bin/env python3\nimport os,time,pathlib\np=pathlib.Path("
            + repr(str(marker))
            + ')\nif not p.exists():\n p.write_text("started")\n os.write(1,b"A"*17)\nelse:\n os.write(1,b"B"*3840)\n time.sleep(60)\n'
        )
        runner.chmod(0o755)
        override = patch.dict(os.environ, {"FORESIGHT_CAPTURE_RUNTIME": str(runner)})
        override.start()
        old = os.environ["PATH"]
        os.environ["PATH"] = str(self.path) + ":" + old
        h = None
        try:
            h = self.lib.fs_capture_start(b"auto", 1, 48000)
            events = []
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                event = owned_json(self.lib, self.lib.fs_event_poll(h, 100))
                if event:
                    events.append(event)
                    if event["type"] == "pcm":
                        break
            gaps = [event for event in events if event["type"] == "gap"]
            self.assertEqual(len(gaps), 1, events)
            self.assertEqual(gaps[0]["discarded_bytes"], 17)
            self.assertEqual(gaps[0]["reason"], "device_or_pipewire_lost")
            self.assertEqual(gaps[0]["exit_status"], 0)
            states = [event["state"] for event in events if event["type"] == "state"]
            self.assertEqual(
                states, ["connecting", "capturing", "connecting", "capturing"]
            )
            frames = [event for event in events if event["type"] == "pcm"]
            self.assertEqual(len(frames), 1, events)
            self.assertEqual(base64.b64decode(frames[0]["data"]), b"B" * 3840)
            self.assertEqual(
                base64.b64decode(frames[0]["event"]["payload"]), b"B" * 3840
            )
        finally:
            if h:
                self.lib.fs_capture_stop(h)
            os.environ["PATH"] = old
            override.stop()

    def test_speech_cancel_finish_and_destroy_active_reaps_worker(self):
        marker = self.path / "speech-worker-pid"
        runner = self.runner(
            "import os,time,pathlib\npathlib.Path("
            + repr(str(marker))
            + ").write_text(str(os.getpid()))\ntime.sleep(60)\n"
        )
        speech = self.lib.fs_speech_create(runner, str(self.model).encode())

        def wait_pid():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if marker.exists() and marker.read_text():
                    return int(marker.read_text())
                time.sleep(0.01)
            self.fail("speech worker did not start")

        try:
            self.assertEqual(self.lib.fs_speech_finish(speech, b"cancel-asr"), 0)
            pid = wait_pid()
            self.assertEqual(self.lib.fs_speech_cancel(speech), 0)
            self.assertEqual(self.lib.fs_speech_cancel(speech), 0)
            events = drain(self.lib, speech)
            self.assertEqual([event["type"] for event in events], ["done"])
            self.assertEqual(events[0]["status"], "cancelled")
            self.assertIsNone(owned_json(self.lib, self.lib.fs_event_poll(speech, 20)))
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            marker.unlink()
            self.assertEqual(self.lib.fs_speech_finish(speech, b"destroy-asr"), 0)
            pid = wait_pid()
            before = time.monotonic()
            self.lib.fs_speech_destroy(speech)
            speech = None
            self.assertLess(time.monotonic() - before, 1)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if speech:
                self.lib.fs_speech_destroy(speech)

    def test_speech_finish_context_owned_and_variable_buffer_conversion(self):
        runner = self.runner(
            'import wave,sys\np=sys.argv[sys.argv.index("-f")+1]\nw=wave.open(p)\nassert w.getframerate()==16000 and w.getnchannels()==1\nassert w.getnframes()==1600\nprint("owned transcript")\n'
        )
        s = self.lib.fs_speech_create(runner, str(self.model).encode())
        samples = (C.c_int16 * 4800)(*([100] * 4800))
        # uneven 48k buffers must retain resampling phase and preserve 100ms
        for offset, count in [(0, 997), (997, 1403), (2400, 2400)]:
            ptr = C.cast(C.byref(samples, offset * 2), C.POINTER(C.c_int16))
            self.assertEqual(self.lib.fs_speech_push(s, ptr, count, 48000), 0)
        self.lib.fs_speech_finish(s, b"asr")
        events = drain(self.lib, s)
        self.assertEqual(events[-1]["status"], "completed")
        self.assertEqual(events[0]["text"].strip(), "owned transcript")
        self.assertEqual(events[0]["end_ms"], 100)
        self.lib.fs_speech_destroy(s)


if __name__ == "__main__":
    unittest.main()
