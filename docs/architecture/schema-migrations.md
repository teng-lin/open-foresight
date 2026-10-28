# Application profile migrations

`Store.schemaVersion` versions `application.db` independently of the three retrieval
helper databases. Both writable and read-only opens refuse a newer version before
changing journal settings. A failed constructor closes its SQLite handle.

Before opening an existing profile for writing, Store qualifies its bytes without
changing original databases or sidecars. Closing even a rejected writable
connection can checkpoint a future WAL. Read-only SQLite can create SHM, and an
immutable connection can miss a committed WAL-only schema version. WAL-mode
profiles therefore use a source-stable private DB+WAL copy, rebuild SHM only in
that private directory, and remove scratch on success or failure. Scratch uses
0700 directories and 0600 files. This copy is a startup qualification cost; live
readers never copy or use immutable and retain ordinary WAL visibility.

DELETE profiles without a rollback journal use direct read-only qualification.
When a journal exists, including an empty journal, the helper, application and
profile-copy tool probe a source-stable private DB+journal copy read-only. SQLite
can fchown an original journal under root and advance ctime even on a read-only
open; original ownership, mode, timestamps and bytes remain protected by copy-time
and final whole-set identity checks. Private copies retain original journal bytes
and absolute superjournal footers unchanged and never perform recovery. On
`SQLITE_READONLY_ROLLBACK`, a conservative read-only verifier checks the original
current header and every applicable original rollback page-1 version, including
record checksums and recognized segment geometry. It never rewrites journals,
follows superjournal paths or decides attached commit state. Unsupported or
uncertain layouts fail actionably; only after compatibility and final
file-identity checks may SQLite recover the original files. The format authority is SQLite's [file format](https://sqlite.org/fileformat.html)
and `pager.c` (`readJournalHdr`, `pager_cksum`, `pager_playback_one_page`).

When an existing non-empty profile is behind, the writable open first takes
SQLite's exclusive locking mode, finishes any pending privacy maintenance (or
refuses the upgrade), and creates a migration backup of the original version.
Writable opens then hold `BEGIN IMMEDIATE` while re-reading the version and applying
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
| 15 | Normalize all action artifact aliases, durable meeting tasks, document-summary cache |
| 16 | Repair legacy Google modification timestamps exactly once for live unedited sources |
| 17 | Canonical ordered document labels and transactional removal of duplicate labels JSON |
| 18 | `content_revisions` with retain/erase triggers for notes, meeting notes, artifacts, meeting tasks and sources |
| 19 | `meetings.title_manually_edited` flag |
| 20 | `sources.generated` and `meeting_notes.enhanced_generated` ownership, meeting index job/state tables, bounded content history and privacy-maintenance markers |
| 21 | Ordinary deletion routes history erasure to `internal.backupErasurePending`; legacy privacy markers keep their full-cleanup meaning |
| 22 | Meeting transcript index outbox: source mapping, progress, changes, segments, deletes, batches, triggers, `source_contents` view and lookup indexes |
| 23 | Typed answer metadata, conversation and proactive scopes, and ordered source selections with foreign keys; malformed and orphan legacy values use a bounded compatibility quarantine |
| 24 | Durable recording sessions/spans, preallocated chunk publication identities, representations, segmentation cursors, ASR leases/jobs, transcript audio links, reader references and media deletion/generation fences |

`ApplicationMigrations.run` defines steps 1–24 and throws for any other
version. `Store.schemaVersion` aliases `applicationSchemaVersion` from
`persistence/application_schema.dart`; `tools/check_architecture_facts.py`
checks this table against the defined steps.

Historical builds used version 1 for multiple additive schemas. Versions 2–6
therefore probe for columns only while adopting those profiles. New stored-data
changes must add a new ordered migration and increase `schemaVersion`; do not
extend an already released step or create tables from feature constructors.

`persistence/schema_migrations.dart` freezes shipped steps 1–15 and all their
private transitive helpers. They do not call current Store, label or query code.
`migration_manifest.json` records per-version executable bodies and complete
closures using canonical Dart tokens, separately from verified symbol/location
mapping. Formatting/comments and the explicit private binding map do not change
digests; changed old behavior cannot be rebaselined by changing a candidate hash.
The initial guard compares against independently exported current reviewed main,
while separately verifying frozen fixture provenance against its recorded
reachable origin. CI proves that ancestry. If main changes the migration set or
closure, refresh/rebase rather than choosing an older source. After introduction,
CI executes the reviewed-main checker and preserves the existing main manifest
prefix. `tool/migration_guard.dart` uses already locked analyzer 12.1.0 and crypto
3.0.7; the exact direct development promotion changes no resolved SDK/tool version.

Step 17 keeps legacy JSON names in first-occurrence order, intentionally removes
duplicates, and appends structured-only names in label-name order. Matching rows
retain source/color/rationale; JSON-only names become manual labels with the
frozen migration allocator. Malformed/non-array/mixed JSON falls back to existing
structured rows. Deleted-source and pre-existing orphan association rows remain
stored. These rules apply to rows still available at step 17: historical step 9
can already discard structured-only names when valid JSON is authoritative, and
remains unchanged.

Durable `document_labels.position` orders every projection and current write.
`sources.labels` remains a JSON read projection; it is no longer a second stored
representation. A portable transactional rebuild preserves source-details keys,
foreign keys, indexes, timestamps and URI while dropping its labels column.
Previously valid saved force layouts adopt the canonical label signature only
when per-document name/source membership is unchanged; stale layouts never become
valid accidentally. Saved coordinates, vectors and document identities remain.

Current SQL lives in the persistence modules: typed `SourceQueries` and
`MeetingQueries`, `SourceStore`, `MeetingStore`, `ModelStore`, `LabelStore`, request
key transactions and output statistics. Store retains connection/transaction
lifetime and compatibility adapters. The old `MeetingWorkflowStore` extension
delegates to MeetingStore; it no longer exports SQL as a reader interface.
`document_parser.dart` owns bounded extraction with separate Linux sandbox and
macOS bundled-extractor implementations. Reader transactions check the supported
schema before dependent rows; connection-local revision tokens are sampled outside
those short synchronous snapshots.

The document-summary cache remains physically stored after a source soft delete.
Revision/content keys and deleted/revision revalidation prevent reuse. Workspace
clear removes tasks, checkpoints, cache rows and scoped preferences/memory. Privacy
maintenance retains durable intent while active readers defer checkpoint/VACUUM;
retries use capped intervals without an attempt cap and resume on reopen.

## Helper schema set

`agent_metadata.db`, `linux_state.db` and `rag_vector.db` each use schema **1**.
Version 0 adopts the legacy DDL and converts JSON embeddings to binary vectors.
All three versions are checked before live writable open, missing-file creation,
settings changes or DDL. Qualification includes relevant journals/WAL/SHM and
source identity stability, using the same conservative protocol described above.
The helper keeps DELETE journal mode and its existing attached-database boundary:
all pending DDL, conversion and version advances commit in one transaction. A
failure rolls back all members and a later start retries. Already-current members
are not reconverted. Recurring revision/generation pruning remains runtime policy
after migration. No index reset or silent rebuild is introduced.

`python3.13 -m tools.migrate_profile` (from the repository root) qualifies application/helper versions before opening
live writable connections or rewriting settings, and preserves every version.
Native tests exercise real hot attached transactions immediately before and after
superjournal deletion, hidden future page-1 states, WAL-only future versions,
missing/current/mixed sets, corrupt JSON rollback/retry and exact original-file
preservation. The application/profile-tool fixtures include checksum-verified
copies of genuine SQLite VFS crash output; native tests generate those states
again through SQLite itself.

Record the loaded SQLite library and version for each acceptance runtime. Host
Linux uses host SQLite; packaged Linux must exercise its bundled library, and
HanSolo's Dart application uses the signed application-owned SQLite 3.54.1
selected through its protected runtime map. Its source identity is checked before
opening connections, with no fallback to Apple's system SQLite. The helper's
SQLite dependency remains unchanged. Host passes establish neither packaged nor
Mac application acceptance.

`test/schema_migrations_test.dart` exercises old-profile upgrades, refusal of
future profiles, rollback after DDL followed by a failed data backfill, successful
retry, Google table ownership, and reopening without repeated conversion writes.
It also kills a writer after a future-version commit and verifies that rejecting
the profile preserves both its main file and uncheckpointed WAL byte for byte.
