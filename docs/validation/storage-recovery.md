# Application storage retention and recovery

Application schema 20 introduced bounded history; schema 21 separates ordinary
backup erasure from full workspace-clear compaction. The application keeps up to 20 previous revisions per entity, with a
32 MiB aggregate UTF-8 snapshot budget and a 90-day age limit. Current content
is preserved even when a previous revision cannot fit. An absent revision is
unavailable for restore; it is not an empty version of the current document.
The policy covers notes, meeting notes, artifacts, meeting tasks and sources.
Replacement and history capture share the same SQLite transaction.

Generated transcript sources are explicitly marked by their producer. Manual
source edits override that classification. Upgrades recognize the exact existing
meeting/source/provenance relationship, excluding manually edited sources;
titles do not classify ownership. Generated live enhanced-note drafts do not
accumulate snapshots. Manual raw notes and manually edited enhanced text retain
bounded history. Historical ambiguous ownership is retained conservatively.

Age cleanup uses a timestamp index in batches of at most 256 revisions. The
application retries maintenance while running, and history reads exclude expired
revisions immediately. The application does not run cleanup while it is closed.
Every application-owned Dart SQLite connection has a 50 ms busy timeout;
application retry/admission policy determines whether an operation is attempted
again. A source import commits its content and metadata together.

Before upgrading an existing profile, the service holds profile ownership and
SQLite retains an exclusive connection lock across an autocommit `VACUUM INTO`
snapshot and the migration transaction. A failure to acquire that lock or create
and verify the snapshot refuses migration. Existing content is not pruned to
make room for the backup. Historical migration definitions and fixtures stay
unchanged; new behavior is an appended version.

Snapshots live in the private `application.db.backups` directory beside the
application database. Directories and files are created as 0700 and 0600,
respectively, using descriptor-anchored operations. Symlinks, hardlinks, foreign
owners, unsafe permissions and unexpected entries cause refusal rather than
permission repair or traversal. Complete snapshots use a single atomic no-replace rename, without a temporary
second hardlink, followed by an atomically published manifest containing schema, source file identity, creation time and checksum.
A scoped SQLite VFS maps only the already-open snapshot and private rollback
journal descriptors; SQLite never reopens their names. This also avoids Darwin
Unix-VFS creation flags that cannot open `/dev/fd` targets. Restore candidates
must pass checksum, source identity, schema and SQLite integrity checks. Source identity uses no-follow directory-relative metadata,
without opening/closing a second descriptor on the live SQLite file. Partial
files are never candidates. At most two completed
pre-upgrade snapshots are retained for seven days, with opportunistic cleanup
at startup and while the application runs. Routine pruning reads bounded
manifest metadata; it does not hash or integrity-scan whole database files. Safe
stale/corrupt copies are excluded by explicit inspection or restore verification
and cannot prevent a later migration. Unsafe paths still refuse admission.
A newly completed backup remains
retained even if the clock moves backwards.

Backups contain deleted data. Clearing the workspace or deleting a content
entity invalidates all managed snapshots and prepared restore copies, and
commits cleanup intent with deletion. Ordinary deletion removes retained history
and managed copies, then checkpoints old WAL frames, without a full database
VACUUM. An active reader can retain older WAL bytes; cleanup remains pending
until the checkpoint succeeds. Full workspace clear and existing legacy privacy
intent retain their separate VACUUM/checkpoint cleanup. A failed cleanup stays
pending across restart. Completion is not reported while a managed copy remains.
Unexpected entries require inspection; cleanup never follows them or deletes unrelated
files to make space.

`MigrationBackups.restoreCopy` requires explicit confirmation of the snapshot's
data-loss point and a compatible schema limit. It produces a separate verified
private copy and preserves the newer profile. This API does not activate a
restore or make an active profile safe to replace. At most one prepared restore
copy is retained for seven days; a newly verified copy replaces the previous
prepared copy. The offline activation owner
must stop every service/read owner, check application, helper and model/binary
compatibility, retain the newer profile separately, and confirm the restored
profile opens before completing recovery. A SQLite snapshot alone does not
provide binary/helper-model rollback.

Linux descriptor-backed snapshot and failure fixtures exercise the production
Store path. Darwin syscall layout, the descriptor-backed SQLite VFS, the owned
runtime and actual offline activation require their own Mac qualification. Source review or
a Linux test pass does not qualify those paths.

These guarantees describe logical content/history deletion and managed backup
removal. The existing source tombstone policy retains its current source body;
source deletion does not promise to scrub that authoritative tombstone. True
row deletion uses SQLite secure_delete, with WAL cleanup qualified separately.
Managed-file unlink and tested SQLite cleanup do not promise an overwrite of
filesystem free blocks, storage firmware, or external filesystem snapshots.
