#!/usr/bin/env python3
"""Persistent local-only SentenceTransformer adapter. stdout is JSON lines only."""
import sys, json, hashlib, pathlib, os
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
def digest(path):
    h = hashlib.sha256()
    for p in sorted(path.rglob('*')):
        if p.is_file():
            h.update(str(p.relative_to(path)).encode())
            with p.open('rb') as f:
                for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()
try:
    from sentence_transformers import SentenceTransformer
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    model = SentenceTransformer(str(root), device='cpu', local_files_only=True)
    tokenizer = model.tokenizer
    identity = digest(root)
    max_tokens = model.max_seq_length - tokenizer.num_special_tokens_to_add(pair=False)
    preprocessing = f"sentence-transformers/window-mean-normalized-v1/max-tokens-{max_tokens}"
    tokenizer_hash = hashlib.sha256()
    for p in sorted(root.rglob('*')):
        if p.is_file() and ('token' in p.name or p.name in ('vocab.txt', 'vocab.json', 'merges.txt', 'spiece.model', 'sentencepiece.bpe.model')):
            tokenizer_hash.update(str(p.relative_to(root)).encode())
            tokenizer_hash.update(p.read_bytes())
    print(json.dumps({'ready': True, 'digest': identity, 'tokenizer_digest': tokenizer_hash.hexdigest(), 'preprocessing': preprocessing, 'dimensions': model.get_sentence_embedding_dimension()}), flush=True)
    for line in sys.stdin:
        try:
            req = json.loads(line)
            if req['op'] == 'embed':
                tokens = tokenizer.encode(req['text'], add_special_tokens=False)
                if len(tokens) > max_tokens:
                    import numpy as np
                    windows = [tokenizer.decode(tokens[i:i+max_tokens], skip_special_tokens=True) for i in range(0, len(tokens), max_tokens)]
                    vector = model.encode(windows, normalize_embeddings=True).mean(axis=0)
                    norm = np.linalg.norm(vector)
                    result = (vector / norm if norm else vector).tolist()
                else:
                    result = model.encode(req['text'], normalize_embeddings=True).tolist()
            elif req['op'] == 'encode':
                result = tokenizer.encode(req['text'], add_special_tokens=False)
            elif req['op'] == 'decode':
                result = tokenizer.decode(req['tokens'], skip_special_tokens=True)
            print(json.dumps({'result': result}), flush=True)
        except Exception as e:
            print(json.dumps({'error': str(e)}), flush=True)
except Exception as e:
    print(json.dumps({'error': str(e)}), flush=True)
    sys.exit(1)
