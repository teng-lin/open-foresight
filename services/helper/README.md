# Retrieval helper

C++ gRPC service using SQLite for document metadata and local embedding workers for retrieval. Protocol definitions live in `proto/rag` and `proto/linux`; the binary descriptor is required to preserve field presence and wire behavior during C++ binding generation.

The helper owns a private Unix socket and storage directory. Its control service reports pipeline readiness and model identity separately from process liveness. Model replacement, revision-aware indexing, deletion and worker lifetime behavior have reusable tests under `tests/helper`.

The compiled `foresight-model` worker supports EmbeddingGemma LiteRT bundles and uncased BERT WordPiece/mean-pooling directories with a native ONNX export. Generation and grounding also run natively. See [native inference](../inference/README.md). Model assets, credentials, user profiles and generated reports are not included in the repository.

Embeddings are stored as versioned little-endian float64 blobs. Legacy JSON vectors migrate once at startup. Retrieval uses an immutable exact VP-tree index and atomically held reader snapshots, so a document replacement or model rebuild can prepare and commit the next index while searches keep reading the previous generation. Each snapshot retains its matching model until its last reader finishes.
