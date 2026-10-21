# Application profile migrations

`Store.schemaVersion` versions `application.db` independently of the retrieval
helper database. Both writable and read-only opens refuse a newer version before
changing journal settings. A failed constructor closes its SQLite handle.

Before opening an existing profile for writing, Store checks its version through
another read-only connection. Otherwise, closing a rejected writable connection
could checkpoint a future database's WAL and rewrite the main file. The probe
resolves symlinks and reads any existing WAL; when no WAL exists it uses a brief
immutable URI connection to avoid creating sidecars. That probe closes before
the writable connection opens. Live read-only Store connections remain ordinary
SQLite readers so they observe subsequent commits.

Writable opens hold `BEGIN IMMEDIATE` while re-reading the version and applying
all pending steps. Each step advances `PRAGMA user_version` inside the same
transaction. A failure or process exit before commit rolls back schema, backfills,
and version together; reopening retries the pending steps. No per-open table or
column repair occurs after the current version has been committed. The same
transaction creates the `workspaceEpoch` preference when it is missing and prunes
request keys older than 24 hours (`Store.requestKeyLifetime`); neither changes
the schema.

| Version | Change |
| --- | --- |
| 1 | Original application tables |
| 2 | Adopt tables added by historical version-1 releases |
| 3 | Note timestamps and enhancement history |
| 4 | Model backend and model type metadata |
| 5 | Structured source URIs with legacy provenance backfill |
| 6 | Conversation/request/model-response history and indexes |
| 7 | Nullable transcript origins and repeatable meeting questions |
| 8 | Google source, folder and calendar tables owned by Store |
| 9 | One-time normalized label conversion and malformed JSON repair |
| 10 | Durable helper deletion retry queue |
| 11 | Structured local-edit flag with legacy provenance backfill |
| 12 | Generation dates on meeting artifacts |
| 13 | `request_keys` for idempotent creates and appends |
| 14 | Artifact generation manifests and fingerprinted meeting-summary checkpoints |

Historical builds used version 1 for multiple additive schemas. Versions 2–6
therefore probe for columns only while adopting those profiles. New stored-data
changes must add a new ordered migration and increase `schemaVersion`; do not
extend an already released step or create tables from feature constructors.

`test/schema_migrations_test.dart` exercises old-profile upgrades, refusal of
future profiles, rollback after DDL followed by a failed data backfill, successful
retry, Google table ownership, and reopening without repeated conversion writes.
It also kills a writer after a future-version commit and verifies that rejecting
the profile preserves both its main file and uncheckpointed WAL byte for byte.
