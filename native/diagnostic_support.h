#ifndef FORESIGHT_DIAGNOSTIC_SUPPORT_H
#define FORESIGHT_DIAGNOSTIC_SUPPORT_H

#include <stdint.h>

// Private system-only diagnostic runtime. IDs are process-local generations,
// never pointers or descriptors. Exactly one context may be reserved for the
// lifetime of a process, including after failed startup. Mappings/contexts are
// retained until process exit; callers must retain the original loaded image.
// Only prepare/spawn/map may block. Parent preparation belongs to the writer,
// spawn to its dedicated owned isolate, and mapping to the exec-child main
// isolate after its independent watcher acknowledgement.
// All other calls are bounded observations/copies (not scheduler guarantees).
enum {
  FS_DIAG_SUPPORT_ERROR = -1,
  FS_DIAG_SUPPORT_RESERVED = 1,
  FS_DIAG_SUPPORT_PREPARED = 2,
  FS_DIAG_SUPPORT_SPAWNING = 4,
  FS_DIAG_SUPPORT_SPAWNED = 8,
  FS_DIAG_SUPPORT_NOT_LIVE = 16,
  FS_DIAG_SUPPORT_REAPED = 32,
  FS_DIAG_SUPPORT_CANCELLED = 64,
  FS_DIAG_SUPPORT_FAILED = 128,
  FS_DIAG_SUPPORT_WATCH_BOUND = 256
};
enum {
  FS_DIAG_EXIT_UNKNOWN = 0,
  FS_DIAG_EXIT_NORMAL = 1,
  FS_DIAG_EXIT_INVOCATION = 64,
  FS_DIAG_EXIT_BOOTSTRAP = 65,
  FS_DIAG_EXIT_RETIREMENT = 66,
  FS_DIAG_EXIT_UNSAFE = 67,
  FS_DIAG_EXIT_OTHER = 68,
  FS_DIAG_EXIT_SIGNAL = 69
};

#ifdef __cplusplus
extern "C" {
#endif

// Copies exactly argc NUL-terminated strings in argv_bytes (including final
// NUL), <=16 entries/2048 bytes/1024 bytes per entry. The already validated
// composition supplies launcher, native ID, parent PID, worker executable and
// worker arguments. No path is opened or resolved here. A successful reserve
// returns generation1; all subsequent operations require that same ID.
uint64_t fs_diag_parent_reserve(const char *native_id, const char *dart_id,
                                const char *catalog_id,
                                const uint8_t *argv_bytes, uint32_t length,
                                uint32_t argc);
int fs_diag_parent_prepare(uint64_t id);
int fs_diag_parent_spawn(uint64_t id);
// Sole coordinator owns poll. Concurrent misuse returns the last published
// status without touching the handle. Check negative ERROR before status bits.
int fs_diag_parent_poll(uint64_t id);
int fs_diag_parent_exit_class(uint64_t id);
int fs_diag_parent_force(uint64_t id);
int fs_diag_parent_heartbeat(uint64_t id);

// Exec-child only. Arm before inherited descriptor scanning; start a separate
// watcher isolate and observe its positive ACK before child_map or any file
// FFI. The first watch call acknowledges arming; bootstrap timeout starts in
// arm.
uint64_t fs_diag_child_arm(int64_t expected_parent, const char *native_id,
                           const char *dart_id, const char *catalog_id);
// Sole watcher owns local heartbeat/deadline snapshots. Concurrent misuse is
// refused without waiting. No file/main-isolate endpoint ownership crosses it.
int fs_diag_child_watch(uint64_t id);
int fs_diag_child_map(uint64_t id);
// Only a mapped child may enter an operation. Before INIT, active notifications
// are idempotent and never renew the single five-second verification lease;
// completion starts a fresh one-second idle INIT budget, which repeated
// inactive calls cannot renew. After INIT, each active call starts its
// five-second lease.
int fs_diag_child_operation(uint64_t id, int active);
// Final exec-child-only process retirement. Never exits a parent context.
// Closed statuses0/65/67 only; no VM teardown waits on held worker/watch FFI.
int fs_diag_child_finish(uint64_t id, int status);

// Sole writer/main-isolate endpoint owner. No concurrent send/receive calls.
// Chunk and capacity <=4056. COMPLETE metadata is exposed only after protocol
// checks; partial payloads retain ownership and must not be decoded.
int fs_diag_support_send(uint64_t id, uint8_t type, uint64_t request_id,
                         uint32_t total_length, const uint8_t *chunk,
                         uint32_t chunk_length);
int fs_diag_support_receive(uint64_t id, uint8_t *output, uint32_t capacity,
                            uint32_t *copied, uint8_t *type,
                            uint64_t *request_id, uint32_t *total_length);

// Closed bounded directory enumeration for diagnostic storage; no libc DIR
// stream. Reads exactly the caller's open directory descriptor from offset 0
// through one fixed RAW_BYTES stack buffer (Linux getdents64, Darwin
// __getdirentries64) and packs every name except "." and ".." into output as
// one length byte plus 1..255 name bytes. Returns the packed length (at most
// OUTPUT_BYTES) or ERROR, or UNSUPPORTED for more than NAMES entries or a
// Darwin MNT_UNION stack that a raw read cannot list completely. capacity must
// be at least OUTPUT_BYTES. No allocation, path, errno or pointer is retained;
// the descriptor remains the caller's to close.
enum {
  FS_DIAG_DIRECTORY_UNSUPPORTED = -2,
  FS_DIAG_DIRECTORY_NAMES = 256,
  FS_DIAG_DIRECTORY_NAME_BYTES = 255,
  FS_DIAG_DIRECTORY_RAW_BYTES = 8192,
  FS_DIAG_DIRECTORY_OUTPUT_BYTES = 65536
};
int fs_diag_directory_names(int descriptor, uint8_t *output, uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
