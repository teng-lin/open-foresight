# Retrieval helper

C++ gRPC service using SQLite for document metadata and local embedding workers for retrieval. Protocol definitions live in `proto/rag` and `proto/linux`; the binary descriptor is required to preserve field presence and wire behavior during C++ binding generation.

The helper owns a private Unix socket and storage directory. Its control service reports pipeline readiness and model identity separately from process liveness. Model replacement, revision-aware indexing, deletion and worker lifetime behavior have reusable tests under `tests/helper`.

Embedding workers support SentenceTransformer model directories and EmbeddingGemma LiteRT bundles. Generation and grounding run through the native adapter and local LiteRT worker. Model assets, credentials, user profiles and generated reports are not included in the repository.
