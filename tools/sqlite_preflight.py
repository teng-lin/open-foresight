"""Read-only schema qualification for offline profile moves; SQLite owns recovery.

Rollback format authority: SQLite fileformat.html and pager.c readJournalHdr /
pager_cksum. Never rewrite journals or follow their absolute superjournal names.
"""

from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile


def identity(path):
    try:
        value = path.lstat()
    except FileNotFoundError:
        return None
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"Schema preflight requires a regular file: {path}")
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_mode,
        value.st_uid,
        value.st_gid,
    )


def profile_identities(source):
    members = [
        source / "application.db",
        *(
            source / "helper" / name
            for name in ("agent_metadata.db", "linux_state.db", "rag_vector.db")
        ),
    ]
    result = {
        Path(str(member) + suffix): identity(Path(str(member) + suffix))
        for member in members
        for suffix in ("", "-journal", "-wal", "-shm")
    }
    for member in members:
        for journal in member.parent.glob(member.name + "-mj*"):
            result[journal] = identity(journal)
    return result


def verify_profile_unchanged(source, originals):
    if profile_identities(source) != originals:
        raise RuntimeError(
            "Database/sidecar changed during schema preflight; retry offline"
        )


def supported(version, maximum):
    if not 0 <= version <= maximum:
        raise RuntimeError(
            f"Unsupported newer database schema version {version} (maximum {maximum})"
        )


def page_one(data, maximum):
    if len(data) < 100 or data[:16] != b"SQLite format 3\0":
        raise RuntimeError("Unrecognized SQLite page-1 header")
    size = int.from_bytes(data[16:18], "big")
    size = 65536 if size == 1 else size
    if (
        not 512 <= size <= 65536
        or size & (size - 1)
        or data[18] != data[19]
        or data[18] not in (1, 2)
    ):
        raise RuntimeError("Unsupported SQLite database geometry")
    supported(struct.unpack_from(">I", data, 60)[0], maximum)
    return data[18] == 2


def journal_versions(path, maximum):
    magic = bytes.fromhex("d9d505f920a163d7")
    with path.open("rb") as file:
        length = path.stat().st_size
        if length < 512:
            raise RuntimeError("Truncated rollback journal")

        def read(offset, size):
            file.seek(offset)
            result = file.read(size)
            if len(result) != size:
                raise RuntimeError("Truncated rollback journal record")
            return result

        offset, sector, page_size = 0, 512, 0
        while offset + sector <= length:
            header = read(offset, 28)
            if header[:12] == bytes(12):
                return
            if (
                page_size
                and int.from_bytes(header[:4], "big") == 0x40000000 // page_size + 1
            ):
                tail = read(length - 16, 16)
                name_length, checksum = struct.unpack_from(">II", tail)
                if name_length + 20 != length - offset or tail[8:] != magic:
                    raise RuntimeError("Unrecognized superjournal footer")
                name = read(offset + 4, name_length)
                if (
                    sum(value if value < 128 else value - 256 for value in name)
                    & 0xFFFFFFFF
                    != checksum
                ):
                    raise RuntimeError("Invalid superjournal checksum")
                return
            if header[:8] != magic:
                raise RuntimeError("Unrecognized rollback journal header")
            count, nonce, pages, next_sector, next_page = struct.unpack_from(
                ">IIIII", header, 8
            )
            if (
                not 32 <= next_sector <= 65536
                or next_sector & (next_sector - 1)
                or not 512 <= next_page <= 65536
                or next_page & (next_page - 1)
                or (page_size and (next_page != page_size or next_sector != sector))
            ):
                raise RuntimeError("Unsupported rollback journal geometry")
            sector, page_size = next_sector, next_page
            if sector > length - offset:
                raise RuntimeError("Truncated rollback journal segment")
            offset += sector
            if count == 0xFFFFFFFF:
                count = (length - offset) // (page_size + 8)
            if count > (length - offset) // (page_size + 8):
                raise RuntimeError("Truncated rollback page records")
            for _ in range(count):
                record = read(offset, page_size + 8)
                page = struct.unpack_from(">I", record)[0]
                if page in (0, 0x40000000 // page_size + 1):
                    raise RuntimeError("Invalid rollback page number")
                if page <= pages:
                    checksum = (
                        nonce
                        + sum(record[4 + at] for at in range(page_size - 200, 0, -200))
                    ) & 0xFFFFFFFF
                    if checksum != struct.unpack_from(">I", record, page_size + 4)[0]:
                        raise RuntimeError("Invalid rollback page checksum")
                    if page == 1:
                        page_one(record[4 : 4 + page_size], maximum)
                offset += page_size + 8
            offset = (offset + sector - 1) // sector * sector


def readonly_version(path):
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        return db.execute("PRAGMA user_version").fetchone()[0]


def qualify_rollback(probe, journal, maximum):
    try:
        supported(readonly_version(probe), maximum)
    except sqlite3.DatabaseError as error:
        if getattr(error, "sqlite_errorcode", None) != sqlite3.SQLITE_READONLY_ROLLBACK:
            raise
        journal_versions(journal, maximum)


def qualify_member(path, maximum, source, originals):
    if not path.exists() or path.stat().st_size == 0:
        return
    with path.open("rb") as file:
        wal_mode = page_one(file.read(100), maximum)
    wal, journal = Path(str(path) + "-wal"), Path(str(path) + "-journal")
    if wal_mode or wal.exists():
        if journal.exists() and journal.stat().st_size:
            raise RuntimeError(
                "Ambiguous WAL/rollback layout; recover with compatible SQLite"
            )
        with tempfile.TemporaryDirectory(prefix="of-schema-") as temporary:
            scratch = Path(temporary)
            scratch.chmod(0o700)
            copy = scratch / "qualification.db"
            shutil.copyfile(path, copy)
            copy.chmod(0o600)
            if wal.exists():
                sidecar = Path(str(copy) + "-wal")
                shutil.copyfile(wal, sidecar)
                sidecar.chmod(0o600)
            verify_profile_unchanged(source, originals)
            supported(readonly_version(copy), maximum)
    elif journal.exists():
        # Even a read-only SQLite open can fchown a rollback journal when root.
        # Keep that metadata write private, including for an empty journal. The
        # absolute superjournal footer is unchanged and is never recovered here.
        with tempfile.TemporaryDirectory(prefix="of-schema-") as temporary:
            scratch = Path(temporary)
            scratch.chmod(0o700)
            copy = scratch / "qualification.db"
            shutil.copyfile(path, copy)
            copy.chmod(0o600)
            sidecar = Path(str(copy) + "-journal")
            shutil.copyfile(journal, sidecar)
            sidecar.chmod(0o600)
            verify_profile_unchanged(source, originals)
            qualify_rollback(copy, journal, maximum)
    else:
        qualify_rollback(path, journal, maximum)


def qualify_profile(source):
    """Return an identity gate; no live writable connection or new files."""
    source = Path(source)
    originals = profile_identities(source)
    qualify_member(source / "application.db", 17, source, originals)
    for member in ("agent_metadata.db", "linux_state.db", "rag_vector.db"):
        qualify_member(source / "helper" / member, 1, source, originals)
    verify_profile_unchanged(source, originals)
    return originals
