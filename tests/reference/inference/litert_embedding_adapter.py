#!/usr/bin/env python3
"""Persistent offline EmbeddingGemma 2 worker; stdout is JSON lines only."""
import argparse
import hashlib
import io
import importlib.metadata
import json
import math
import os
from pathlib import Path
import sys

MAC_REFERENCE_BUNDLE_SHA256 = '0b4fe50337c5a45a8e4361bc5738b678f9ffa88c0d5908701226b8cd12dd1465'


def load(path, gpu=False):
    if importlib.metadata.version('litert-lm') != '0.18.0':
        raise RuntimeError('This adapter requires litert-lm==0.18.0')
    import litert_lm
    import sentencepiece
    from litert_lm_builder import litertlm_peek
    from litert_lm_builder import litertlm_header_schema_py_generated as schema
    from litert_lm_builder.runtime.proto import embedding_metadata_pb2

    path = path.resolve(strict=True)
    header = litertlm_peek.read_litertlm_header(str(path), io.StringIO())
    sections = header.SectionMetadata()
    tokenizer_bytes = None
    metadata = None
    with path.open('rb') as source:
        for i in range(sections.ObjectsLength()):
            section = sections.Objects(i)
            if section.DataType() not in (schema.AnySectionDataType.SP_Tokenizer,
                                          schema.AnySectionDataType.EmbeddingMetadataProto):
                continue
            begin, end = section.BeginOffset(), section.EndOffset()
            if not 0 <= begin < end <= path.stat().st_size or end - begin > 32*1024*1024:
                raise ValueError('Invalid embedding bundle section bounds')
            source.seek(begin)
            data = source.read(end - begin)
            if section.DataType() == schema.AnySectionDataType.SP_Tokenizer:
                tokenizer_bytes = data
            else:
                metadata = embedding_metadata_pb2.EmbeddingMetadata()
                metadata.ParseFromString(data)
    if tokenizer_bytes is None or metadata is None:
        raise ValueError('Embedding bundle requires model metadata and SentencePiece tokenizer')
    if not metadata.embedding_model_type.HasField('embedding_gemma_v2'):
        raise ValueError('This adapter supports EmbeddingGemma 2 bundles')
    tokenizer = sentencepiece.SentencePieceProcessor(model_proto=tokenizer_bytes)
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1048576), b''):
            digest.update(block)
    engine = litert_lm.EmbeddingEngine(
        str(path), backend=(litert_lm.Backend.GPU() if gpu else litert_lm.Backend.CPU(thread_count=4)),
        audio_backend=litert_lm.Backend.CPU(thread_count=4),
        min_input_length=128, max_input_length=512)
    options = litert_lm.EmbeddingOptions(
        normalize=True, output_size=768, insert_special_tokens=True,
        input_overflow_strategy=litert_lm.InputOverflowStrategy.CHUNK_AND_AVERAGE)
    model_digest = digest.hexdigest()
    # The checksum-matched Mac helper forwards plain text for document and
    # query requests. Synthetic retrieval scores corroborate that static path.
    preprocessing = ('mac-raw-all-tasks-v2' if model_digest == MAC_REFERENCE_BUNDLE_SHA256
                     else 'raw-rpc/search-query-document-none-v1')
    info = {'ready': True, 'digest': model_digest,
            'tokenizer_digest': hashlib.sha256(tokenizer_bytes).hexdigest(),
            'dimensions': 768, 'backend': 'litert-lm-embedding-gpu' if gpu else 'litert-lm-embedding-cpu',
            'preprocessing': 'embeddinggemma2/' + preprocessing + '/l2-768/chunk-average-512/bos-eos/audio-cpu/' + ('gpu' if gpu else 'cpu'),
            'modalities': ['text']}
    return engine, tokenizer, options, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', nargs='?', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--gpu', action='store_true')
    args = parser.parse_args()
    # Native GPU drivers can log to fd 1. Reserve a separate descriptor for
    # the protocol and send both Python and native diagnostic output to stderr.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), 'w', buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    engine = None
    try:
        if args.check:
            import litert_lm
            import sentencepiece
            from litert_lm_builder import litertlm_peek
            if importlib.metadata.version('litert-lm') != '0.18.0':
                raise RuntimeError('This adapter requires litert-lm==0.18.0')
            return 0
        if args.model is None:
            raise ValueError('A local embedding bundle is required')
        engine, tokenizer, options, info = load(args.model, args.gpu)
        print(json.dumps(info), file=protocol, flush=True)
        for line in sys.stdin:
            try:
                request = json.loads(line)
                if request['op'] == 'encode':
                    result = tokenizer.encode(request['text'], out_type=int)
                elif request['op'] == 'decode':
                    result = tokenizer.decode(request['tokens'])
                elif request['op'] == 'embed':
                    task = request.get('task', 'document')
                    if task not in ('query', 'document', 'raw'):
                        raise ValueError('Unknown embedding task')
                    prefix = {'query': 'task: search result | query: ',
                              'document': 'title: none | text: ', 'raw': ''}[task]
                    if info['digest'] == MAC_REFERENCE_BUNDLE_SHA256:
                        prefix = ''
                    result = engine.compute_embedding(prefix + request['text'], options=options).embedding
                    if len(result) != 768 or not all(math.isfinite(x) for x in result):
                        raise ValueError('Invalid embedding vector')
                    norm = math.sqrt(sum(x*x for x in result))
                    if not 0.9999 < norm < 1.0001:
                        raise ValueError('Embedding vector is not normalized')
                else:
                    raise ValueError('Unknown adapter operation')
                print(json.dumps({'result': result}), file=protocol, flush=True)
            except Exception as error:
                print(json.dumps({'error': str(error)}), file=protocol, flush=True)
        return 0
    except Exception as error:
        print(json.dumps({'error': str(error)}), file=protocol, flush=True)
        return 1
    finally:
        if engine is not None:
            engine.close()
        protocol.close()


if __name__ == '__main__':
    sys.exit(main())
