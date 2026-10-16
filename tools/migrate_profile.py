#!/usr/bin/env python3
"""Move an offline desktop profile without adopting the separate virtual profile.

Stop the app and its helper first. Refuses open files, existing destinations,
active meetings, symlinks, and cross-filesystem moves. Backups contain private
data and belong outside the source tree.
"""
import argparse
import fcntl
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys


def check_open_profile(source):
    """Refuse live users on both supported hosts; fail closed on scan errors."""
    if sys.platform == 'darwin':
        scan = subprocess.run(
            ['/usr/sbin/lsof', '-nP', '-Fpn', '+D', str(source)],
            text=True, capture_output=True, timeout=30)
        if scan.returncode not in (0, 1) or scan.stderr.strip():
            raise RuntimeError('Cannot verify offline profile: ' + scan.stderr.strip())
        owner = None
        for line in scan.stdout.splitlines():
            if line.startswith('p'):
                owner = line[1:]
            elif line.startswith('n') and owner != str(os.getpid()):
                raise RuntimeError(f'Profile is open in process {owner}; stop it first')
        return
    if not Path('/proc/self/fd').is_dir():
        raise RuntimeError('Cannot verify offline profile on this platform')
    for process in Path('/proc').glob('[0-9]*'):
        if process.name == str(os.getpid()):
            continue
        try:
            for fd in (process / 'fd').iterdir():
                try:
                    target = os.readlink(fd)
                except (FileNotFoundError, PermissionError):
                    continue
                if target.startswith(str(source) + '/'):
                    raise RuntimeError(f'Profile is open in process {process.name}; stop it first')
        except (FileNotFoundError, PermissionError):
            continue


def replace_prefix(value, mappings):
    for old, new in mappings:
        if value == old or value.startswith(old + '/'):
            return new + value[len(old):]
    return value


def migrate(source, destination, backup, old_bundle, new_bundle, copy_external=False):
    source, destination, backup = map(Path, (source, destination, backup))
    if source.is_symlink() or destination.is_symlink():
        raise ValueError('Profile symlinks are not supported')
    source, destination, backup = (p.absolute() for p in (source, destination, backup))
    if not (source / 'application.db').is_file():
        raise ValueError('Source application.db is missing')
    if destination.exists() or backup.exists():
        raise ValueError('Destination and backup must not already exist')
    if any(a.is_relative_to(b) for a, b in ((destination, source), (backup, source), (backup, destination), (destination, backup))):
        raise ValueError('Profile and backup directories must be separate')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError('Atomic profile migration requires the same filesystem')
    # Cooperate with the helper's own single-owner lock as well as checking app
    # and worker descriptors. Do not move SQLite WALs from a running process.
    lock_path = source / 'helper/.helper.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock, (source / '.application.lock').open('a') as application_lock:
        # Dart FileLock uses POSIX record locks, distinct from flock on Linux.
        fcntl.lockf(application_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check_open_profile(source)
        with sqlite3.connect(source / 'application.db') as db:
            active = db.execute("SELECT count(*) FROM meetings WHERE state IN ('recording','transcribing')").fetchone()[0]
            if active:
                raise RuntimeError('Finish the active meeting before migrating')
        for database in source.rglob('*.db'):
            with sqlite3.connect(database) as db:
                if db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                    raise RuntimeError('Database integrity check failed')
                if db.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] != 0:
                    raise RuntimeError('Database is busy')
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, backup, copy_function=shutil.copy2)
        backup.chmod(0o700)
        mappings = [(str(source), str(destination)),
                    (str(Path(old_bundle) / 'share/foresight'), str(Path(new_bundle) / 'share/open-foresight')),
                    (str(old_bundle), str(new_bundle))]
        source.rename(destination)
        try:
            with sqlite3.connect(destination / 'application.db') as db:
                for kind, path, runtime in db.execute('SELECT kind,path,runtime FROM models').fetchall():
                    new_path = replace_prefix(path, mappings)
                    if copy_external and path and new_path == path and Path(path).is_file():
                        relative = Path('models/imported') / kind / Path(path).name
                        asset = destination / relative
                        asset.parent.mkdir(parents=True, exist_ok=True)
                        if asset.exists():
                            raise ValueError('External model destination already exists')
                        # Copy to avoid modifying another session through shared
                        # inodes; preserve timestamps for runtime cache identity.
                        shutil.copy2(path, asset)
                        new_path = str(asset)
                    db.execute('UPDATE models SET path=?,runtime=? WHERE kind=?',
                               (new_path, replace_prefix(runtime, mappings), kind))
                # Only owned file references are rewritten. User-authored text,
                # citations, cloud provenance, and model digests stay intact.
                for row_id, uri in db.execute('SELECT source_id,source_uri FROM source_details').fetchall():
                    updated = replace_prefix(uri, mappings)
                    if uri.startswith('file://'):
                        updated = 'file://' + replace_prefix(uri[7:], mappings)
                    if updated != uri:
                        db.execute('UPDATE source_details SET source_uri=? WHERE source_id=?', (updated, row_id))
                if db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                    raise RuntimeError('Migrated database integrity check failed')
            metadata = destination / 'helper/agent_metadata.db'
            if metadata.exists():
                with sqlite3.connect(metadata) as db:
                    for key in ('cache_dir', 'embedding_model_path'):
                        row = db.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
                        if row:
                            value = replace_prefix(row[0], mappings)
                            if key == 'embedding_model_path' and copy_external:
                                with sqlite3.connect(destination / 'application.db') as app:
                                    model = app.execute("SELECT path FROM models WHERE kind='embedding'").fetchone()
                                    if model:
                                        value = model[0]
                            db.execute('UPDATE settings SET value=? WHERE key=?', (value, key))
        except Exception:
            # Preserve the failed copy for diagnosis; restore the complete
            # pre-migration profile, including external-model registrations.
            destination.rename(destination.with_name(destination.name + '.migration-failed'))
            shutil.copytree(backup, source, copy_function=shutil.copy2)
            raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--backup', required=True, type=Path)
    parser.add_argument('--old-bundle', required=True, type=Path)
    parser.add_argument('--new-bundle', required=True, type=Path)
    parser.add_argument('--copy-external-models', action='store_true')
    args = parser.parse_args()
    print(migrate(args.source, args.destination, args.backup, args.old_bundle,
                  args.new_bundle, args.copy_external_models))


if __name__ == '__main__':
    main()
