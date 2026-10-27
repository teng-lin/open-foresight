# Database and audio backups

`AudioProfileBackups` creates an explicit user-owned copy of the current database
and every current usable, published recording representation. Lossless chunks
needed by unfinished transcription are included alongside retained Opus. The
manifest reports already unavailable chunks; a backup cannot recreate missing
originals. Installed binaries/models, migration rollback snapshots, partial
capture/transform files and external exported files/destination receipts are
excluded. Migration snapshots retain their existing metadata-only meaning.

Creation initially requires physical capture and workers to be quiesced through
the entire operation. The service-owned callback includes authorized startup
capture reconciliation, native finish and final publication drain; a stopped DB
row alone is insufficient. Pending privacy erasure, unrelated readers or active
DB worker leases refuse the operation. The caller holds the profile/media owner
until all copying and pin release finish. This is a deliberate initial offline
restriction, rather than a claim of online audio backup.

A transaction pins every included representation in the source database. The
existing protected SnapshotVfs writes a consistent VACUUM database snapshot. That
snapshot determines the inventory, which must still have its source pins before
copying. Media is paged by representation identity in groups of 64, copied in a
filesystem isolate through anchored no-follow private files, and checked by
whole-file SHA and byte count. JSON-lines inventory rows are bounded individually;
there is no meeting-sized Dart list or 128/256-chunk truncation.

The root manifest binds format/schema, database SHA, inventory SHA, generation,
workspace epoch, representation count, copied media bytes and unavailable chunk
count. Every directory/file is synchronized before a completed private staging
directory is atomically published at an absent destination. Existing files or
profiles are never overwritten. Destinations must be outside protected profile
and cache roots. Concrete CLI/runtime composition now supplies the selected
profile/runtime, installation, LiteRT cache and Python cache roots from
service-owned configuration for both creation and restore. These roots never
come from an RPC argument. Unknown independently configured profiles are not
inventoried by this policy.

`inspect` verifies the root, SQLite integrity/schema, generation/epoch, exact
streamed DB-to-inventory correspondence and every media checksum. Paths must
match the canonical managed generation/session layout and recognized raw WAV or
retained Opus representation identity. A rewritten inventory cannot add an
arbitrary file to the copy. Format/codec validation originally occurs at durable
media publication; backup preserves those exact manifest-bound bytes. Native
playback/ASR validates codec input again before using restored bytes.

`restoreToNewProfile` accepts only an absent authorized profile directory. It
validates the complete source, copies into a private sibling staging directory,
verifies the exact database payload before making new-copy safety changes, and
binds the copied DB inode to the restored media generation only after all media
is copied and validated. Unfinished exports become blocked with
`backup_restore_requires_new_destination`; original external grants cannot run
from another profile. The source backup and original profile stay unchanged.
Atomic no-replace directory publication makes the new profile available only
when its DB/media/binding are ready. Normal media startup recovers old ephemeral
leases/references under its inherited-worker ownership lock.

This is new-profile restore, not in-place active-profile activation. The user
selects it explicitly with `FORESIGHT_DATA`. Existing snapshot identity,
activation, exchange and interrupted-restore recovery remain unchanged.

## CLI integration

`AudioBackupCommand` parses these commands without loading a runtime or profile:

```text
foresight-service --audio-backup-create=NEW_DIRECTORY
foresight-service --audio-backup-inspect=BACKUP_DIRECTORY
foresight-service --audio-backup-restore=BACKUP_DIRECTORY --new-profile=NEW_DIRECTORY
```

The service entrypoint supplies prepared runtime configuration and a
`WithAudioBackupOwner` scope for create. That scope owns the real profile lock,
media owner and physical quiescence barrier until the action settles. Inspection
and new-profile restore need no live profile. This module does not silently
substitute a SQL flag for that barrier. The concrete service entrypoint now dispatches these commands before normal
service startup. Creation acquires installation/profile/media ownership, runs
actual native recovery without opening devices or starting ASR/codecs, then
copies while ownership stays held. An uncertain actual native retirement keeps
all owners pinned and requires the transient utility process to exit.

A failed or cancelled copy may leave an unpublished private staging directory.
`AudioBackupIncomplete` reports its exact location; the runner prints that
location. Copies outside the managed profile are user-owned backup data and are
not erased by deleting the original meeting. They must not be silently hidden or
treated as managed disposable caches. A process-crash orphan is recognizable by
the explicit `.foresight-backup-UUID` or `.foresight-audio-restore-UUID` name; names
alone never authorize adoption, replacement or automatic recursive deletion.
