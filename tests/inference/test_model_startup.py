"""Recovered initialization retry and model-owned cache recovery behavior."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('startup_runner', ROOT / 'services/inference/macos/litert_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ModelStartupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.model = self.root / 'model.litertlm'
        self.model.write_bytes(b'model')
        self.cache = self.root / 'owned-cache/gpu'
        self.cache.mkdir(parents=True)

    def api(self, outcomes):
        instances, events = [], []
        class Engine:
            def __init__(self, model, **settings):
                self.index = len(instances)
                self.closed = False
                self.model, self.settings = model, settings
                self._lib = types.SimpleNamespace(
                    litert_lm_session_config_add_stop_token_sequence=lambda: None)
                instances.append(self)
                events.append(('initialize', self.index))
                if outcomes[self.index] is not None:
                    raise outcomes[self.index]
            def close(self):
                if not self.closed:
                    self.closed = True
                    events.append(('close', self.index))
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
            def create_conversation(self, *, stop_token_ids=None, **settings): pass
        api = types.ModuleType('litert_lm')
        api.Engine = Engine
        api.Backend = types.SimpleNamespace(GPU=lambda: 'gpu', CPU=lambda **kw: ('cpu', kw))
        return api, instances, events

    def test_retry_preserves_settings_and_clear_mkdir_shutdown_order(self):
        api, instances, events = self.api([RuntimeError('first'), None])
        backend, audio, vision = object(), object(), object()
        settings = dict(backend=backend, audio_backend=audio, vision_backend=vision,
                        max_num_tokens=4096, cache_dir=str(self.cache))
        def clear(model, cache):
            self.assertFalse(instances[0].closed)
            self.assertEqual((model, cache), (self.model, self.cache))
            events.append(('clear', 0))
        original_mkdir = Path.mkdir
        def mkdir(path, *args, **kwargs):
            if path == self.cache:
                self.assertFalse(instances[0].closed)
                events.append(('mkdir', 0))
            return original_mkdir(path, *args, **kwargs)
        with patch.object(Path, 'mkdir', mkdir):
            with runner.initialize_generation_engine(api, self.model, self.cache,
                    clear_cache=clear, warn=lambda _: None, **settings) as engine:
                self.assertIs(engine, instances[1])
                self.assertEqual(instances[0].settings, instances[1].settings)
                self.assertIs(engine.settings['backend'], backend)
                self.assertIs(engine.settings['audio_backend'], audio)
                self.assertIs(engine.settings['vision_backend'], vision)
        self.assertEqual(events, [('initialize', 0), ('clear', 0), ('mkdir', 0),
                                  ('close', 0), ('initialize', 1), ('close', 1)])

    def test_vision_fallback_preserves_text_audio_and_cache_after_two_failures(self):
        for backend in ('cpu', 'gpu'):
            with self.subTest(backend=backend):
                api, instances, events = self.api([RuntimeError('first'), RuntimeError('second'), None])
                with runner.initialize_generation_engine(api, self.model, self.cache,
                        clear_cache=lambda *args: events.append(('clear', 0)), warn=lambda _: None,
                        backend=backend, audio_backend='cpu', vision_backend='gpu',
                        visual_tokens=280, max_num_tokens=4096, cache_dir=str(self.cache)) as engine:
                    self.assertIs(engine, instances[2])
                    self.assertEqual([e.settings['vision_backend'] for e in instances], ['gpu', 'gpu', None])
                    self.assertNotIn('visual_tokens', instances[2].settings)
                    for e in instances:
                        self.assertEqual(e.settings['backend'], backend)
                        self.assertEqual(e.settings['audio_backend'], 'cpu')
                        self.assertEqual(e.settings['max_num_tokens'], 4096)
                        self.assertEqual(e.settings['cache_dir'], str(self.cache))
                self.assertTrue(all(e.closed for e in instances))
                self.assertEqual(events, [('initialize', 0), ('clear', 0), ('close', 0),
                                         ('initialize', 1), ('close', 1), ('initialize', 2), ('close', 2)])

    def test_third_vision_failure_propagates_after_final_shutdown(self):
        final = RuntimeError('text-only fallback also failed')
        api, instances, _ = self.api([RuntimeError('first'), RuntimeError('second'), final])
        with self.assertRaises(RuntimeError) as raised:
            with runner.initialize_generation_engine(api, self.model, self.cache,
                    clear_cache=lambda *args: None, warn=lambda _: None,
                    backend='gpu', audio_backend='cpu', vision_backend='gpu', visual_tokens=560):
                self.fail('Failed fallback must not yield an engine')
        self.assertIs(raised.exception, final)
        self.assertTrue(all(e.closed for e in instances))

    def test_public_model_aliases_select_backend_and_visual_budget(self):
        for model_type in (14, 15, 8, 9, 10):
            self.assertEqual(runner.generation_model_config(model_type),
                             dict(vision_backend='gpu', audio_backend='cpu', visual_tokens=280))
        for model_type in (16, 12):
            self.assertEqual(runner.generation_model_config(model_type),
                             dict(vision_backend='gpu', audio_backend='gpu', visual_tokens=560))
        self.assertIsNone(runner.generation_model_config(0)['vision_backend'])
        self.assertIsNone(runner.generation_model_config(4)['vision_backend'])

    def test_owned_c_api_initializer_sets_budget_before_create_and_frees_settings(self):
        events = []
        class Call:
            def __init__(self, name, result=None):
                self.name, self.result, self.failures = name, result, 0
            def __call__(self, *args):
                events.append((self.name, args))
                if self.failures:
                    self.failures -= 1
                    raise RuntimeError('injected native settings cleanup error')
                return self.result
        lib = types.SimpleNamespace()
        for name, result in [('create', 42), ('set_max_num_tokens', None),
                ('set_num_threads', None), ('set_audio_num_threads', None),
                ('set_cache_dir', None), ('set_enable_speculative_decoding', None),
                ('set_max_vision_tokens_per_image', None), ('delete', None)]:
            setattr(lib, 'litert_lm_engine_settings_' + name, Call(name, result))
        lib.litert_lm_engine_create = Call('engine_create', 101)
        lib.litert_lm_engine_delete = Call('engine_delete')
        class CPU:
            thread_count = 4
            def get_name(self): return 'cpu'
        class GPU:
            def get_name(self): return 'gpu'
        class Abstract:
            def __init__(self, **settings):
                self.enable_speculative_decoding = None
                self.__dict__.update(settings)
        class Engine:
            def close(self):
                if self._engine_ptr:
                    self._lib.litert_lm_engine_delete(self._engine_ptr)
                    self._engine_ptr = None
        api = types.ModuleType('litert_lm')
        api.Engine = Engine
        api.interfaces = types.SimpleNamespace(AbstractEngine=Abstract, CPU=CPU)
        ffi = types.ModuleType('litert_lm._ffi')
        ffi._get_lib = lambda: lib
        with patch.dict('sys.modules', {'litert_lm': api, 'litert_lm._ffi': ffi}):
            configured = runner.configured_engine_api(api)
            with runner.initialize_generation_engine(configured, self.model, self.cache,
                    clear_cache=lambda *args: None, backend=CPU(), audio_backend=CPU(),
                    vision_backend=GPU(), max_num_tokens=4096, cache_dir=str(self.cache),
                    visual_tokens=280) as engine:
                self.assertEqual(engine._engine_ptr, 101)
        names = [name for name, _ in events]
        self.assertLess(names.index('set_max_vision_tokens_per_image'), names.index('engine_create'))
        self.assertEqual(events[names.index('set_max_vision_tokens_per_image')][1], (42, 280))
        self.assertEqual(names.count('delete'), 1)
        self.assertEqual(names[-1], 'engine_delete')
        self.assertEqual(names.count('engine_delete'), 1)
        # A failure after native engine creation must retain that engine until
        # the recovered shutdown boundary, including failure of settings delete.
        for failures in (1, 3):
            with self.subTest(settings_cleanup_failures=failures):
                events.clear()
                lib.litert_lm_engine_settings_delete.failures = failures
                with patch.dict('sys.modules', {'litert_lm': api, 'litert_lm._ffi': ffi}):
                    configured = runner.configured_engine_api(api)
                    def attempt():
                        with runner.initialize_generation_engine(configured, self.model, self.cache,
                                clear_cache=lambda *args: events.append(('clear', ())),
                                warn=lambda _: None, backend=CPU(), audio_backend=CPU(),
                                vision_backend=GPU(), max_num_tokens=4096,
                                cache_dir=str(self.cache), visual_tokens=280):
                            pass
                    if failures == 3:
                        with self.assertRaisesRegex(RuntimeError, 'settings cleanup error'): attempt()
                    else:
                        attempt()
                names = [name for name, _ in events]
                self.assertEqual(names.count('engine_delete'), 3 if failures == 3 else 2)
                self.assertEqual(names.count('engine_create'), names.count('engine_delete'))
                self.assertLess(names.index('clear'), names.index('engine_delete'))
                self.assertLess(names.index('engine_delete'), names.index('engine_create', names.index('engine_create') + 1))


    def test_second_failure_rethrows_without_cpu_or_third_attempt(self):
        second = RuntimeError('second')
        api, instances, events = self.api([RuntimeError('first'), second])
        clears = []
        with self.assertRaises(RuntimeError) as raised:
            with runner.initialize_generation_engine(api, self.model, self.cache,
                    clear_cache=lambda *args: clears.append(args), warn=lambda _: None,
                    backend='gpu', cache_dir=str(self.cache)):
                self.fail('Failed initialization must not yield an engine')
        self.assertIs(raised.exception, second)
        self.assertEqual(len(clears), 1)
        self.assertEqual([engine.settings['backend'] for engine in instances], ['gpu', 'gpu'])
        self.assertTrue(all(engine.closed for engine in instances))

    def test_successful_startup_and_body_error_do_not_trigger_recovery(self):
        for body_error in (False, True):
            with self.subTest(body_error=body_error):
                api, instances, _ = self.api([None])
                clears = []
                def generate():
                    with runner.initialize_generation_engine(api, self.model, self.cache,
                            clear_cache=lambda *args: clears.append(args)):
                        if body_error:
                            raise RuntimeError('generation failed')
                if body_error:
                    with self.assertRaisesRegex(RuntimeError, 'generation failed'): generate()
                else:
                    generate()
                self.assertEqual(len(instances), 1)
                self.assertTrue(instances[0].closed)
                self.assertEqual(clears, [])

    def arguments(self, **changes):
        values = dict(check=False, model=str(self.model), backend='gpu', query_detector=False,
                      probe=True, serve=False, prompt=None, tools=None, json_schema=None,
                      max_output_tokens=256)
        values.update(changes)
        return types.SimpleNamespace(**values)

    def test_production_probe_uses_same_backend_recovery_and_actual_cache_cleanup(self):
        api, instances, _ = self.api([RuntimeError('stale cache'), None])
        cache_file = self.cache / 'model.litertlm_old.program_cache'
        cache_file.write_bytes(b'stale')
        output = io.StringIO()
        with patch.dict(runner.sys.modules, {'litert_lm': api}), \
                patch.object(runner.importlib.metadata, 'version', return_value='0.18.0'), \
                patch.dict(runner.os.environ, {'FORESIGHT_LITERT_CACHE': str(self.cache.parent)}), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            runner.run(self.arguments())
        self.assertFalse(cache_file.exists())
        self.assertEqual([engine.settings['backend'] for engine in instances], ['gpu', 'gpu'])
        self.assertEqual(instances[0].settings, instances[1].settings)
        self.assertEqual(instances[1].settings['max_num_tokens'], 4096)
        self.assertEqual(json.loads(output.getvalue())['worker_protocol'], 1)
        self.assertTrue(all(engine.closed for engine in instances))

    def test_dedicated_query_detector_keeps_its_direct_gpu_only_startup(self):
        api, instances, _ = self.api([RuntimeError('GPU unavailable')])
        cache_file = self.cache / 'model.litertlm_old.program_cache'
        cache_file.write_bytes(b'preserve query cache')
        with patch.dict(runner.sys.modules, {'litert_lm': api}), \
                patch.object(runner.importlib.metadata, 'version', return_value='0.18.0'), \
                patch.dict(runner.os.environ, {'FORESIGHT_LITERT_CACHE': str(self.cache.parent)}):
            with self.assertRaisesRegex(RuntimeError, 'GPU unavailable'):
                runner.run(self.arguments(query_detector=True))
        self.assertEqual(len(instances), 1)
        self.assertEqual(instances[0].settings['backend'], 'gpu')
        self.assertEqual(instances[0].settings['max_num_tokens'], 512)
        self.assertTrue(cache_file.exists())

    def test_runtime_check_does_not_initialize_or_touch_model_cache(self):
        api, instances, _ = self.api([])
        with patch.dict(runner.sys.modules, {'litert_lm': api}), \
                patch.object(runner.importlib.metadata, 'version', return_value='0.18.0'):
            runner.run(self.arguments(check=True, model=None))
        self.assertEqual(instances, [])

    def test_cache_scans_are_nonrecursive_prefix_scoped_and_adjacent_contains_based(self):
        selected = [self.cache / 'model.litertlm_old.program_cache', self.cache / 'model_gpu.bin',
                    self.root / 'model_mldrift_payload.bin', self.root / 'model.xnnpack_cache.partial']
        preserved = [self.cache / 'other_model.xnnpack_cache', self.root / 'model.program_cache',
                     self.root / 'other_mldrift_payload.bin', self.root / 'model.xnnpack_cach']
        nested = self.cache / 'model_nested'
        nested.mkdir()
        preserved.append(nested / 'model.program_cache')
        for path in selected + preserved:
            path.write_bytes(b'cache fixture')
        runner.clear_model_cache(self.model, self.cache)
        self.assertTrue(all(not path.exists() for path in selected))
        self.assertTrue(all(path.exists() for path in preserved))
        self.assertTrue(self.model.exists())
        self.assertTrue(nested.is_dir())

    def test_matching_file_symlink_is_unlinked_without_touching_its_target(self):
        target = self.root / 'unrelated.bin'
        target.write_bytes(b'preserve target')
        link = self.cache / 'model.litertlm_link.cache'
        link.symlink_to(target)
        runner.clear_model_cache(self.model, self.cache)
        self.assertFalse(link.is_symlink())
        self.assertEqual(target.read_bytes(), b'preserve target')

    def test_outer_listing_error_logs_and_stops_the_remaining_scan(self):
        adjacent = self.root / 'model_mldrift_cache.bin'
        adjacent.write_bytes(b'preserve after listing failure')
        warnings = []
        original = Path.iterdir
        def iterdir(path):
            if path == self.cache:
                raise PermissionError('cannot list cache')
            return original(path)
        with patch.object(Path, 'iterdir', iterdir):
            runner.clear_model_cache(self.model, self.cache, warn=warnings.append)
        self.assertEqual(len(warnings), 1)
        self.assertTrue(adjacent.exists())

    def test_delete_retries_five_times_with_100_to_400ms_delays_then_warns(self):
        path = self.cache / 'model.cache'
        path.write_bytes(b'busy')
        delays, warnings = [], []
        with patch.object(Path, 'unlink', side_effect=PermissionError('busy')) as unlink:
            self.assertFalse(runner.delete_model_cache_file(path, sleep=delays.append, warn=warnings.append))
        self.assertEqual(unlink.call_count, 5)
        self.assertEqual(delays, [0.1, 0.2, 0.3, 0.4])
        self.assertEqual(len(warnings), 1)
        self.assertTrue(path.exists())

    def test_delete_missing_path_succeeds_without_sleep_or_unlink(self):
        with patch.object(Path, 'unlink') as unlink:
            self.assertTrue(runner.delete_model_cache_file(self.cache / 'missing',
                sleep=lambda _: self.fail('unexpected sleep'), warn=lambda _: self.fail('unexpected warning')))
        unlink.assert_not_called()

    def test_transient_delete_failure_stops_retrying_after_success(self):
        path = self.cache / 'model.cache'
        path.write_bytes(b'cache')
        delays, calls = [], []
        original = Path.unlink
        def unlink(item):
            calls.append(item)
            if len(calls) < 3: raise PermissionError('temporarily busy')
            return original(item)
        with patch.object(Path, 'unlink', unlink):
            self.assertTrue(runner.delete_model_cache_file(path, sleep=delays.append,
                warn=lambda _: self.fail('unexpected terminal warning')))
        self.assertEqual(len(calls), 3)
        self.assertEqual(delays, [0.1, 0.2])
        self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()
