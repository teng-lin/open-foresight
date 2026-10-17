#!/usr/bin/env python3
"""Evaluate the pinned public bundle directly, without changing a user index."""

import argparse
import importlib.metadata
import json
import math
from pathlib import Path
import time

from download_embeddinggemma2 import (
    ROOT,
    FILENAME,
    REVISION,
    REPOSITORY,
    SHA256,
    SIZE,
    file_hash,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        type=Path,
        default=ROOT / "models/local/embeddinggemma2" / SHA256[:12] / FILENAME,
    )
    parser.add_argument(
        "--report", type=Path, default=ROOT / "test-results/embeddinggemma2-direct.json"
    )
    parser.add_argument("--backend", choices=["cpu", "gpu"], default="cpu")
    args = parser.parse_args()
    if args.model.stat().st_size != SIZE or file_hash(args.model) != SHA256:
        raise ValueError("Model does not match the pinned public artifact")

    import litert_lm

    started = time.monotonic()
    engine = litert_lm.EmbeddingEngine(
        str(args.model.resolve()),
        backend=(
            litert_lm.Backend.GPU()
            if args.backend == "gpu"
            else litert_lm.Backend.CPU(thread_count=4)
        ),
        min_input_length=128,
        max_input_length=512,
    )
    load_seconds = time.monotonic() - started
    options = litert_lm.EmbeddingOptions(
        normalize=True,
        output_size=768,
        input_overflow_strategy=litert_lm.InputOverflowStrategy.ERROR,
    )
    timings = []

    def embed(text):
        started = time.monotonic()
        vector = engine.compute_embedding(text, options=options).embedding
        timings.append(time.monotonic() - started)
        if not (len(vector) == 768 and all(math.isfinite(x) for x in vector)):
            raise RuntimeError("Verification failed")
        if not (abs(math.sqrt(sum(x * x for x in vector)) - 1) < 1e-4):
            raise RuntimeError("Verification failed")
        return vector

    documents = [
        "The project launch is postponed until Friday because final testing is unfinished.",
        "The cafeteria serves vegetarian lunch every Wednesday.",
        "An astronomer discovered a comet beyond Neptune.",
    ]
    queries = [
        "When is the release scheduled after the testing delay?",
        "On what day can I get a meat-free meal?",
        "What did the scientist find in the outer solar system?",
    ]
    rankings = []
    try:
        vectors = [embed("title: none | text: " + text) for text in documents]
        for expected, query in enumerate(queries):
            vector = embed("task: search result | query: " + query)
            scores = [
                sum(a * b for a, b in zip(vector, doc, strict=False)) for doc in vectors
            ]
            ranking = sorted(
                range(len(documents)), key=lambda i: scores[i], reverse=True
            )
            if not (ranking[0] == expected):
                raise RuntimeError((query, scores))
            rankings.append(
                {"expected": expected, "ranking": ranking, "scores": scores}
            )
    finally:
        engine.close()

    report = {
        "model_repository": REPOSITORY,
        "revision": REVISION,
        "model_sha256": SHA256,
        "model_bytes": SIZE,
        "runtime_version": importlib.metadata.version("litert-lm"),
        "backend": "GPU" if args.backend == "gpu" else "CPU; four threads",
        "tested_modalities": ["text"],
        "embedding_dimensions": 768,
        "all_vectors_finite": True,
        "all_vectors_l2_normalized": True,
        "query_document_prefixes": "Public model card retrieval prefixes, not recovered Mac configuration",
        "load_seconds": load_seconds,
        "embedding_seconds": timings,
        "independent_query_rankings": rankings,
        "limitations": [
            "Not yet connected to Linux helper or user index",
            "Exact checksum and selected output dimension of Mac downloaded weights remain unknown",
            "Image/audio/video inference and import flows remain unverified",
            "Three fixture queries are a runtime sanity check, not a quality benchmark",
        ],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
