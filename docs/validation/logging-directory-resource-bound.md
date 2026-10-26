# Logging directory enumeration: resource bound

Diagnostic storage lists its `logs` root and slot directories many times per
admission and classification. Those listings no longer use libc directory
streams. Their memory is fixed by this repository's code, not by libc's DIR
sizing, by filesystem metadata such as `st_blksize`, or by the shipped libc
version.

## Mechanism

- `fs_diag_directory_names(descriptor, output, capacity)` in
  `native/diagnostic_support.c` is the only enumerator.
  - It checks that the descriptor is a directory, rewinds it to offset 0, and
    reads it with a raw system call into one 8 KiB stack buffer: Linux
    `getdents64`, Darwin `__getdirentries64`.
  - It validates every record: header, record length, NUL-terminated name of
    1 to 255 bytes, no `/`, at most two dot entries, and on Darwin the declared
    name length.
  - It writes each name except `.` and `..` into the caller's buffer as one
    length byte plus the name.
  - It refuses more than 256 names, more than 258 records, a reported read
    size larger than the buffer, a capacity below 64 KiB, and on Darwin a
    `MNT_UNION` stack, which a raw read can't list completely.
  - It makes no allocation, keeps no path, errno or pointer, and makes at most
    259 reads per call.
- `BackupDirectory` accepts an optional per-instance `BackupDirectoryReader`,
  and `child()` passes it on.
  - When a reader is set, `visitEntries` (and so `entries`, `containsEntry` and
    `replace`) opens its usual fresh duplicate of the anchor at or above the
    minimum descriptor and checks that the duplicate has the anchor's identity.
  - It then gives exactly that duplicate to the reader and closes it.
  - The packed output is parsed with the existing name and UTF-8 checks, and
    `.`, `..`, `/`, NUL, zero-length or overrunning names, and more than 256
    names are refused.
  - With no reader set, the libc path is unchanged.
- `DiagnosticStorage.admit(directoryReader:)` sets the reader on the profile
  directory, so `logs` and every slot inherit it. No separate metadata gate is
  needed before each enumeration.
- The exec-child worker passes `DiagnosticNativeFunctions.directoryReader`
  (optional table entry 15).
  - An image without `fs_diag_directory_names` still loads, but admission
    reports `unsupportedFilesystem` and never falls back to libc.
  - Only logging is disabled; the application keeps working.

## Bound per enumeration

| Item | Bytes | Lifetime |
|---|---|---|
| Raw read buffer (native stack) | 8192 | one native call |
| Packed-name buffer (`calloc`, Dart) | 65536 | one `visitEntries` call |
| Decoded names (Dart strings) | at most 256 names of at most 255 bytes | caller; `entries()` keeps them, `containsEntry` doesn't |
| Descriptors | one duplicate | closed before `visitEntries` returns |

Listings run one at a time, so the transient workspace is about 72 KiB at
once. Nothing new lasts for the process lifetime. The wider 512 KiB worker
envelope is still the runtime owner's to accept. These figures cover only
directory listing.

## Supported filesystems

- No filesystem is newly excluded. On Linux, `getdents64` output comes from
  the kernel's generic `filldir64` for every filesystem, so ext4, XFS, btrfs,
  overlayfs and tmpfs all produce the same record format. The existing
  `localFileSystem` policy still decides which filesystems are admitted.
- On Darwin, ordinary APFS directories are read directly. `MNT_UNION` stacks
  are refused for completeness, not for memory.

## Evidence and limits

- The native test `diagnostic_directory` covers:
  - real directories, the actual descriptor, and repeated fresh and reused
    descriptors;
  - exactly 256 names of 255 bytes (65536 bytes of output) accepted, with a
    guard region untouched, and 257 names refused;
  - injected malformed records, an endless directory, and read sizes over the
    buffer;
  - argument errors;
  - zero libc DIR calls, using interposed `opendir`, `fdopendir`, `readdir` and
    `closedir`.
- Guard-deletion mutants exercised the checks above. The oversized-read
  negative control remains in the native test; ASan confirmation of that
  specific mutation is pending and is not claimed by this qualification.
- Real filesystems that were run are recorded with each qualification run. The
  ext4, XFS and real `MNT_UNION` cases require mounts and are not executed by
  the unprivileged CI fixtures. The union refusal is an injected `fstatfs`
  control on a real APFS descriptor.
- `__getdirentries64` is the libsystem_kernel entry that Apple Libc's own
  `readdir` calls. It isn't declared in a public header, so its declaration
  here copies Libc's private `telldir.h` prototype. Each Mac qualification run
  must show that the library links and the enumerator passes against the
  installed system.
