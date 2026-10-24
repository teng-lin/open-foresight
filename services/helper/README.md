# Retrieval helper

C++ gRPC service using SQLite for document metadata and local embedding workers for retrieval. Protocol definitions live in `proto/rag` and `proto/linux`; the binary descriptor is required to preserve field presence and wire behavior during C++ binding generation.

The helper owns a private Unix socket and storage directory. Its control service reports pipeline readiness and model identity separately from process liveness. Model replacement, revision-aware indexing, deletion and worker lifetime behavior have reusable tests under `tests/helper`.

The compiled `foresight-model` worker supports EmbeddingGemma `.litertlm` bundles on CPU and GPU. Generation and grounding also run natively. See [native inference](../inference/README.md). Model assets, credentials, user profiles and generated reports are not included in the repository.

Embeddings are stored as versioned little-endian float64 blobs. Legacy JSON vectors migrate once at startup. Retrieval uses an immutable exact VP-tree index and shared reader snapshots protected by a short pointer lock, so a document replacement or model rebuild can prepare and commit the next index while searches keep reading the previous generation. Each snapshot retains its matching model until its last reader finishes.

Incremental meeting transcripts use the application-owned
`foresight.transcript.v1.TranscriptIndex` service in
`proto/linux/transcript_index.proto`; the recovered RAG descriptor is unchanged.
Protocol 1.1.0 and helper schema 2 are required together. Schema 1's legacy
migration is retained, followed by an attached transaction that adds transcript
cursor and segment metadata. Derived helper indexes are rebuilt from the
application store; they are not application backups.

Each finalized transcript row has a stable parent/epoch/channel/segment identity.
Only changed bounded segments are tokenized and embedded. Internal segment IDs
are reserved, while search results and document filters retain the parent source
ID for citations. Finalized speech has no mutable provisional tail; explicit
amendments replace only their affected segment. A delta has at most 64 upserts,
64 deletes, 1 MiB of serialized data, and 64 KiB per segment. Ordinary appends do
not concatenate or rewrite the full transcript. Explicit reconciliation resets
one parent atomically; ordinary full-document replacement also erases its old
segment index. Model replacement rebuilds segment vectors through the existing
atomic generation mechanism.

GetCursor reads committed epoch, revision, last application transcript row ID
and segment count in constant work. The cursor revision is a transaction
sequence; applications separately track their content revision. ApplyDelta uses
an expected-revision check, and an exact retry of the last bounded delta performs
no additional tokenization or embedding. Cursor metadata commits with vectors
before the search snapshot is published. A lost response can therefore be
reconciled without replaying the transcript prefix. Delete/clear removes segment
content, vectors and cursor metadata; losing the metadata member invalidates
reserved segment rows rather than exposing internal IDs as citations.

`helper_transcript_index` runs the actual helper with the deterministic test
adapter. It covers retry/conflict, mutation, cancellation, commit-boundary crashes,
restart, model rebuild, citation filtering, erasure and fixed 64/128-segment work
measurements. It reports tokenizer input bytes/tokens, embedded bytes/chunks and
snapshot construction counts, requiring a processed-content ratio at most 2.5.
These controlled model results do not qualify production model or physical-audio
acceptance.
