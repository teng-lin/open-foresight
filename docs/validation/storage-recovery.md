# Application storage retention and recovery

Application schema 20 introduced bounded history; schema 21 separates ordinary
backup erasure from full workspace-clear compaction. The application keeps up to 20 previous revisions per entity, with a
32 MiB aggregate UTF-8 snapshot budget per entity and a 90-day age limit. Total
history grows with the number of entities; this is not a profile-wide byte cap. Current content
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
SQLite first establishes WAL under normal locking, then retains an exclusive
connection lock across an autocommit `VACUUM INTO` snapshot and the migration
transaction. It returns to normal locking before readers open. Any prior durable
privacy cleanup intent must finish before the new snapshot is created; blocked
cleanup refuses migration and retains its intent. A failure to acquire that lock or create
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
Future-dated copies beyond five minutes of clock skew are excluded and pruned.
The just-created backup is protected during admission even if the clock moves
backwards; older future-dated copies cannot occupy retention slots indefinitely.

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

## Offline restore activation

`RestoreActivation` (`lib/src/persistence/restore_activation.dart`) and its
utility, the restore route of `foresight-service` (`bin/service.dart` with
`lib/src/persistence/restore_command.dart`), make a verified snapshot the
profile's live database. `--restore-list` reports candidates with their
data-loss point; `--restore-activate=S --accept-data-loss=S` must name the same
snapshot twice (otherwise exit 64, nothing changed); `--restore-recover`
resolves an interrupted activation. The service's diagnostic-worker and model
transport routes keep precedence. The route is part of the service source; this
document does not claim that any installed package has been qualified with
it.

The route is dispatched after those worker routes and validates its arguments
and the confirmation first, without loading anything. Then it calls
`ApplicationRuntimeBootstrap.prepare(DiagnosticHost.service)` once, which
selects, metadata-checks and initializes the mandatory SQL support image and
freezes the SQLite mapping before any profile lock or SQLite call. It then
starts a *transient* logging session for the selected profile: the role the
service's own `--status`/`--stop` utility modes use, which takes no owner or
candidate slot. A restore is a utility, not a service profile owner. Without a
verified selection (an installed `foresight-service` layout, or source-build
metadata compiled in) it refuses with exit 1 before touching the profile; there
is no lazy or environment-selected SQL fallback. Logging closes through the
session's own bounded close. A failure there never changes the utility's
output or exit status, and when the close reports that an owner must be
retired, the flushed process exits explicitly with the utility's status.

Activation runs in its own process and takes the real profile lock through
`acquireServiceProfileLock`; it refuses (exit 75) while a service owns the
profile, and refuses in a process that hosts an owner. That lock is
cooperative: every Open Foresight owner takes it, and it is what makes the
profile offline. Holding it, activation lists the snapshot again (checksum,
manifest source identity, schema, SQLite integrity). Before changing anything
it refuses a live profile newer than this build (below) and a profile that
still records deletion intent (`internal.privacyMaintenancePending` or
`internal.backupErasurePending`): those snapshots may hold content the user
deleted, and replacing the live database would drop the intent that erases
them.

It then switches the live database to the rollback journal and takes a
write-free `BEGIN EXCLUSIVE`. It does that on a new connection, then repeats
the schema and deletion-intent checks under the lock. A writer that ignores the
profile lock and commits between the early checks and the lock is caught and
refused; the journal mode has changed by then, and Store re-establishes WAL. A
fresh connection is required: with the SQLite 3.45.1 loaded in these tests, a
connection that had read in WAL mode still returned its stale cached pages
after leaving WAL under its own EXCLUSIVE lock, and missed such a commit.

SQLite's locks are a second check, and they prove less than the profile lock.
The switch fails, and activation refuses with the live database still in WAL
mode, while another connection is inside a transaction or is a WAL connection
that has read (rw or ro), because WAL keeps that shared lock until close. An
idle rollback-journal connection holds no lock and is not detected. Tested with
3.45.1: after the exchange it still reads the database it opened, now the
displaced one. Its writes, a switch to WAL and an open write transaction are
all refused with SQLITE_READONLY_DBMOVED (1032), because the name now holds
another file. It leaves no journal, even when killed. A connection opened but
not yet used is not detectable either. The prerequisite therefore stands: stop
every Open Foresight process, and no other program may keep the profile
database open.

The quiesce lock on the previous database is held until the names have been
exchanged, and through any reverse exchange. The staged copy is reserved with
its own write-free `BEGIN EXCLUSIVE` before the exchange; it is checked to be a
rollback-journal file first, so no WAL is named after the staged path. Its
descriptor follows the file through the exchange, so the restored database is
never unreserved under the live name. Confirmation (identity, schema,
integrity) runs on that connection, because any other descriptor on the file
would drop its POSIX locks when closed. The reservation is kept through
retention of the previous database and marker removal. A connection that
ignores the profile lock gets SQLITE_BUSY from either database while names
change; it cannot commit into a restored database that a later failure rolls
back. `test/restore_activation_test.dart` keeps the original prototype defect
(a Store writer in the gap left its WAL attached to the restored file) and the
lost-commit case found in review as regressions.

`restoreCopy` re-verifies the snapshot. Activation writes a durable marker
(snapshot checksum, previous database identity and schema), moves the prepared
copy beside the live database, rechecks its checksum and swaps the two names in
one atomic exchange (Linux `renameat2` `RENAME_EXCHANGE`, Darwin `renameatx_np`
`RENAME_SWAP`). The live name is never absent. A filesystem without exchange
refuses before the live name changes. A failed rename, fsync or confirmation
swaps the names back and removes only the staged copy, which held the live name
only while reserved. If SQLite files of the restored database already exist, it
stays live instead and the previous database is retained as below. After
process death, `--restore-recover` (or the next activation) identifies files by the
marker. The previous database's identity is always retained; the snapshot copy
is removed. A marker with nothing staged is resolved, and if the previous
database was already retained it is found by identity and reported. Anything
else, or a staged file without a marker, is reported and left untouched. Death
before staging leaves at most the prepared copy in `application.db.backups`,
which is a managed restore copy (one copy, seven days, erased with every
backup) and is replaced by the next activation.

While a staged database or published marker exists, `Store` and
`Store.readOnly` refuse before any SQLite file is opened
(`persistence/restore_pending.dart` checks directory names only), so ordinary
startup cannot open, migrate or clear the profile while the previous database
is still outside managed erasure. A real service start exits with that refusal.
Nothing is discarded automatically: the bytes stay until `--restore-recover` (or the
next activation, which runs recovery first) retains them as below. Activation
and recovery use their own SQLite connections, not `Store`, so the guard does
not block them.

The previous database is retained as a managed migration snapshot of the
restored profile, in `application.db.backups`, under the existing
`MigrationBackups` names, manifest and owner-only mode. It is listed as a
candidate, so activating it undoes the restore, and the existing policy applies
unchanged: at most two snapshots and seven days, and `erase()` on every
workspace clear or content deletion, with the erasure intent persisted until
that succeeds. The command reports its name and latest retention time, and
activation also reports previous profiles its recovery retained
(`recovered_snapshots`).
Snapshots taken from the previous database no longer match the restored file's
identity; the next prune removes them.

Schema compatibility is injected. The command passes this build's
`Store.schemaVersion`, and no snapshot newer than it is accepted. A live
profile newer than it is refused too, by Store's own `SqlitePreflight` (page-1
header and a private copy of any WAL, read-only) before any writable connection
or journal-mode change: its bytes, journal mode and sidecars stay unchanged.
For a downgrade, restore with the newer installation that supports the live
profile, then install the older application; never run an older command against
a newer live profile. Restoring does not roll
back the application binary, helper, native runtime or models; the operator
must install compatible ones. On first open, Store upgrades an older restored
schema and takes a new pre-upgrade snapshot, which does not evict the retained
previous profile.

Data-loss point: every change after the snapshot's `created` time leaves the
active profile and remains only in the displaced snapshot, for at most its
retention.

Linux tests on btrfs and tmpfs run against the current development source with
the mandatory SQL support bootstrap: in-process and fixture children through
the test bootstrap, and the real service and restore command compiled with
source-build metadata through their production bootstrap. The SQLite they load
is the system 3.45.1: the Linux native build used links the system library, and
only macOS verifies the pinned 3.54.1 source id when it loads SQLite. Which
SQLite a Linux package installs as `lib/libsqlite3.so` was not examined. They
cover:
- a real service process refusal (library and command);
- cross-process readers;
- idle WAL (rw and ro) and rollback-journal connections;
- Store, raw SQLite and committing writers before, at and after the exchange
  and through retention, including a failure injected after a writer at the
  exchange;
- writers racing the early schema and deletion-intent checks;
- newer-live-schema refusal with unchanged bytes and journal mode;
- pending-erasure refusal;
- erasure and expiry of the displaced profile through the production Store and
  `MigrationBackups`;
- rollback after injected failures at each stage;
- child-process death at every stage from the quiesce to after the retain
  rename;
- Store and real service refusal until recovery;
- the command itself, including its refusal without a verified runtime
  selection.

They do not qualify an installed or packaged command or the pinned 3.54.1
runtime, and they do not inject kernel fsync errors. Darwin exchange, `fchmod`
and the macOS command require their own qualification.

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
