#!/usr/bin/env python3
"""Opt-in real-model check of recovered vision startup and native ownership.

Uses a caller-selected local SDK/model and a synthetic image in an owned
profile. No downloads, credentials, original application data or shared caches.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def red_image(path):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' +
        chunk(b'IHDR', struct.pack('>IIBBBBB', 128, 128, 8, 2, 0, 0, 0)) +
        chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 128) * 128)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--model-type', type=int, choices=(14, 15, 16), default=14)
    parser.add_argument('--backend', choices=('cpu', 'gpu'), required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    import litert_lm
    spec = importlib.util.spec_from_file_location('vision_runner', ROOT / 'services/inference/macos/litert_runner.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    config = runner.generation_model_config(args.model_type)
    with args.model.open('rb') as model_stream:
        model_digest = hashlib.file_digest(model_stream, 'sha256').hexdigest()
    report = {'backend': args.backend, 'model_type': args.model_type, 'requested': config,
              'model_sha256': model_digest,
              'acceptance_passed': False}
    engine = None
    try:
        with tempfile.TemporaryDirectory(prefix='foresight-vision-runtime-') as temporary:
            root = Path(temporary)
            (root / 'cache').mkdir(mode=0o700)
            image = root / 'red.png'
            red_image(image)
            backend = litert_lm.Backend.GPU() if args.backend == 'gpu' else litert_lm.Backend.CPU(thread_count=4)
            audio = litert_lm.Backend.GPU() if config['audio_backend'] == 'gpu' else litert_lm.Backend.CPU(thread_count=4)
            with runner.initialize_generation_engine(runner.configured_engine_api(litert_lm), args.model, root / 'cache',
                    backend=backend, vision_backend=litert_lm.Backend.GPU(), audio_backend=audio,
                    visual_tokens=config['visual_tokens'], enable_speculative_decoding=True, max_num_tokens=4096, cache_dir=str(root / 'cache')) as engine:
                report['effective_vision_backend'] = engine.vision_backend.get_name() if engine.vision_backend else None
                report['text_backend'] = engine.backend.get_name()
                report['audio_backend'] = engine.audio_backend.get_name()
                if report['effective_vision_backend'] != 'gpu':
                    raise RuntimeError('Vision startup used text-only fallback')
                messages = [litert_lm.Message.user(litert_lm.Contents.of(
                    litert_lm.Content.ImageFile(str(image)), 'Examine this image.'))]
                with engine.create_conversation(messages=messages,
                        thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
                        max_output_tokens=64) as conversation:
                    answer = str(conversation.send_message('What is the main color? Reply with one color word.'))
                    report['answer'] = answer
                    if 'red' not in answer.lower():
                        raise RuntimeError('Synthetic red image answer did not identify red')
                # The new initializer reuses the SDK's cancellation and native
                # conversation lifetime. Cancel active streamed work, close it,
                # then prove the same engine can create a fresh conversation.
                cancelled = False
                with engine.create_conversation(
                        thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
                        max_output_tokens=512) as conversation:
                    try:
                        for chunk in conversation.send_message_async('Count the integers from 1 to 200, one per line.'):
                            if not cancelled and str(chunk):
                                # This C API returns void; its ctypes return value is unspecified.
                                engine._lib.litert_lm_conversation_cancel_process(conversation._ptr)
                                cancelled = True
                    except RuntimeError as error:
                        if not cancelled:
                            raise
                        report['stream_error_after_cancel'] = str(error)
                report['cancel_requested_after_stream_delta'] = cancelled
                report['cancelled_stream_closed'] = cancelled and conversation._ptr is None
                if not report['cancelled_stream_closed']:
                    raise RuntimeError('Stream cancellation/close ownership failed')
                with engine.create_conversation(
                        thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
                        max_output_tokens=32) as retry:
                    report['reuse_answer'] = str(retry.send_message('What is 2 + 2? Reply with one digit.'))
                    if report['reuse_answer'].strip() != '4':
                        raise RuntimeError('Engine reuse after cancellation failed')
            report['native_engine_closed'] = engine._engine_ptr is None
            if not report['native_engine_closed']:
                raise RuntimeError('Native engine remained live after close')
            report['acceptance_passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if engine is not None:
            report['native_engine_closed'] = engine._engine_ptr is None
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
