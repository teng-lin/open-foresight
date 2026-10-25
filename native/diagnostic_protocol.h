#ifndef FORESIGHT_DIAGNOSTIC_PROTOCOL_H
#define FORESIGHT_DIAGNOSTIC_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
#include <atomic>
typedef std::atomic<uint64_t> fs_diag_atomic64;
#define FS_DIAG_ASSERT static_assert
#define FS_DIAG_ALIGNOF alignof
#else
#include <stdatomic.h>
typedef _Atomic(uint64_t) fs_diag_atomic64;
#define FS_DIAG_ASSERT _Static_assert
#define FS_DIAG_ALIGNOF _Alignof
#endif

#if !defined(__x86_64__) && !defined(__aarch64__) && !defined(__arm64__)
#error Diagnostic shared pages require the supported 64-bit target ABI
#endif
#if !defined(__BYTE_ORDER__) || !defined(__ORDER_LITTLE_ENDIAN__) ||           \
    __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Diagnostic shared page native words require little-endian targets
#endif

enum {
  FS_DIAG_PAGE_BYTES = 16384,
  FS_DIAG_HEADER_BYTES = 256,
  FS_DIAG_FRAME_BYTES = 20,
  FS_DIAG_REQUEST_OFFSET = 256,
  FS_DIAG_REQUEST_PAYLOAD = 8192,
  FS_DIAG_REPLY_OFFSET = 8480,
  FS_DIAG_REPLY_PAYLOAD = 512,
  FS_DIAG_COPY_LIMIT = 4096,
  // Fund the wire-header snapshot and saved-header copy within each call's
  // 4096-byte copy allowance, including the first receive chunk.
  FS_DIAG_CHUNK_BYTES = FS_DIAG_COPY_LIMIT - 2 * FS_DIAG_FRAME_BYTES,
  FS_DIAG_PROTOCOL_VERSION = 1,
  FS_DIAG_CHILD_FD = 10,
  FS_DIAG_HELLO = 1,
  FS_DIAG_INIT = 2,
  FS_DIAG_RESULT = 3,
  FS_DIAG_ADMIT = 4,
  FS_DIAG_CLASSIFY = 5,
  FS_DIAG_APPEND = 6,
  FS_DIAG_HEALTH = 7,
  FS_DIAG_RETIRE = 8,
  FS_DIAG_RETIRED = 9
};
#define FS_DIAG_PAGE_MAGIC UINT32_C(0x5044464f)
#define FS_DIAG_MAX_SEQUENCE UINT64_C(0x7fffffffffffffff)
#define FS_DIAG_CHALLENGE_MASK UINT64_C(0x1fffffffffffffff)
#define FS_DIAG_PROBE UINT64_C(0x2000000000000000)
#define FS_DIAG_FORCE_RETIRE UINT64_C(0x4000000000000000)

// Immutable words are initialized before the page is published. Every mutable
// word is a naturally aligned, lock-free 64-bit atomic; the runtime checks
// atomic_is_lock_free after mapping. No peer word supplies a pointer or offset.
typedef struct fs_diag_header {
  uint32_t magic;
  uint16_t version;
  uint16_t header_bytes;
  uint64_t generation;
  uint64_t application_pid;
  fs_diag_atomic64 child_pid;
  uint8_t nonce[32];
  uint8_t native_id[32];
  uint8_t dart_id[32];
  uint8_t catalog_id[32];
  fs_diag_atomic64 parent_heartbeat;
  fs_diag_atomic64 control_command;
  fs_diag_atomic64 control_ack;
  fs_diag_atomic64 request_published;
  fs_diag_atomic64 request_consumed;
  fs_diag_atomic64 reply_published;
  fs_diag_atomic64 reply_consumed;
  fs_diag_atomic64 state;
  fs_diag_atomic64 child_heartbeat;
  uint8_t reserved[24];
} fs_diag_header;

typedef struct fs_diag_page {
  fs_diag_header header;
  uint8_t request[FS_DIAG_FRAME_BYTES + FS_DIAG_REQUEST_PAYLOAD];
  uint8_t request_padding[12];
  uint8_t reply[FS_DIAG_FRAME_BYTES + FS_DIAG_REPLY_PAYLOAD];
  uint8_t reserved[7372];
} fs_diag_page;

FS_DIAG_ASSERT(sizeof(fs_diag_atomic64) == 8, "atomic word ABI");
FS_DIAG_ASSERT(FS_DIAG_ALIGNOF(fs_diag_atomic64) == 8, "atomic alignment ABI");
FS_DIAG_ASSERT(sizeof(fs_diag_header) == FS_DIAG_HEADER_BYTES, "header ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, version) == 4, "version ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, header_bytes) == 6, "header size ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, generation) == 8, "generation ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, application_pid) == 16, "parent ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, child_pid) == 24, "child ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, nonce) == 32, "nonce ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, native_id) == 64,
               "native identity ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, dart_id) == 96, "Dart identity ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, catalog_id) == 128, "catalog ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, parent_heartbeat) == 160,
               "heartbeat ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, control_command) == 168, "command ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, control_ack) == 176, "ack ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, request_published) == 184,
               "request ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, request_consumed) == 192,
               "request ack ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, reply_published) == 200, "reply ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, reply_consumed) == 208,
               "reply ack ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, state) == 216, "state ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, child_heartbeat) == 224,
               "child beat ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_header, reserved) == 232, "reserved ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_page, request) == FS_DIAG_REQUEST_OFFSET,
               "request cell ABI");
FS_DIAG_ASSERT(offsetof(fs_diag_page, reply) == FS_DIAG_REPLY_OFFSET,
               "reply cell ABI");
FS_DIAG_ASSERT(sizeof(fs_diag_page) == FS_DIAG_PAGE_BYTES, "fixed page ABI");

#undef FS_DIAG_ASSERT
#undef FS_DIAG_ALIGNOF

#ifdef __cplusplus
extern "C" {
#endif

// These process-local cursors never come from the shared page. One owner uses
// each cursor. A broken peer poisons its channel permanently; there is no retry
// or wrap that could interpret stale bytes as a newly admitted request.
typedef struct fs_diag_send_cursor {
  uint64_t sequence;
  uint64_t request_id;
  uint32_t length;
  uint32_t copied;
  uint8_t type;
  int pending;
  int failed;
} fs_diag_send_cursor;

typedef struct fs_diag_receive_cursor {
  uint64_t sequence;
  uint64_t pending_sequence;
  uint64_t request_id;
  uint32_t length;
  uint32_t copied;
  uint8_t type;
  uint8_t frame[FS_DIAG_FRAME_BYTES];
  int failed;
} fs_diag_receive_cursor;

enum {
  FS_DIAG_REQUEST_CHANNEL = 1,
  FS_DIAG_REPLY_CHANNEL = 2,
  FS_DIAG_CHANNEL_ERROR = -1,
  FS_DIAG_CHANNEL_EMPTY = 0,
  FS_DIAG_CHANNEL_PARTIAL = 1,
  FS_DIAG_CHANNEL_COMPLETE = 2
};

// All arguments except page bytes are local, trusted API inputs. Per-call copy
// limits include publishing: larger INIT frames require successive chunks.
// Nothing is published until all chunks have been copied.
// EMPTY means the previous publication is still owned by the peer (busy).
// The context owner enforces one HELLO/INIT, monotonic request IDs, matching
// replies and final retirement, and propagates either cursor failure to both
// directions. Cursors stay native-owned; Dart does not mirror their layouts.
int fs_diag_page_supported(const fs_diag_page *page);
int fs_diag_publish(fs_diag_page *page, int channel,
                    fs_diag_send_cursor *cursor, uint8_t type,
                    uint64_t request_id, uint32_t total_length,
                    const uint8_t *chunk, uint32_t chunk_length);

// Copies at most capacity <=4096 bytes, reporting the copied count only after
// checking the publication/header again. COMPLETE consumes the entire frame;
// PARTIAL retains one bounded offset. The caller discards its partial buffer on
// ERROR and validates the complete untrusted payload before decoding it. Header
// stability is a torn-frame check, not authentication of a malicious peer.
int fs_diag_receive(fs_diag_page *page, int channel,
                    fs_diag_receive_cursor *cursor, uint8_t *output,
                    uint32_t capacity, uint32_t *copied);

#ifdef __cplusplus
}
#endif
#endif
