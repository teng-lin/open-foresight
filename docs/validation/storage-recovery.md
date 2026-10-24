# Application storage retention and recovery

Application schema 20 keeps up to 20 previous revisions per entity, with a
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
permission repair or traversal. Complete snapshots have an atomically published
manifest containing schema, source file identity, creation time and checksum.
Restore candidates must pass checksum, source identity, schema and SQLite
integrity checks. Partial files are never candidates. At most two completed
pre-upgrade snapshots are retained for seven days, with opportunistic cleanup
at startup and while the application runs. A newly completed backup remains
retained even if the clock moves backwards.

Backups contain deleted data. Clearing the workspace or deleting a content
entity invalidates all managed snapshots and prepared restore copies, and
commits cleanup intent with deletion. A failed cleanup stays pending across
restart. Completion is not reported while a managed snapshot remains. Unexpected
entries require inspection; cleanup never follows them or deletes unrelated
files to make space.

`MigrationBackups.restoreCopy` requires explicit confirmation of the snapshot's
data-loss point and a compatible schema limit. It produces a separate verified
private copy and preserves the newer profile. This API does not activate a
restore or make an active profile safe to replace. The offline activation owner
must stop every service/read owner, check application, helper and model/binary
compatibility, retain the newer profile separately, and confirm the restored
profile opens before completing recovery. A SQLite snapshot alone does not
provide binary/helper-model rollback.

Linux descriptor-backed snapshot and failure fixtures exercise the production
Store path. Darwin syscall layout, `/dev/fd` behavior, owned SQLite runtime and
actual offline activation require their own Mac qualification. Source review or
a Linux test pass does not qualify those paths.
