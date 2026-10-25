#ifndef FORESIGHT_DIAGNOSTIC_ENDPOINT_H
#define FORESIGHT_DIAGNOSTIC_ENDPOINT_H

#include "diagnostic_protocol.h"

// Private native-owned state, never a Dart-mirrored layout or peer-provided
// pointer. The process owner must validate mapping/build identity first. One
// caller owns the endpoint; the independent watcher touches header atomics
// only.
typedef struct fs_diag_endpoint {
  fs_diag_page *page;
  fs_diag_send_cursor send;
  fs_diag_receive_cursor receive;
  uint64_t next_request_id;
  uint64_t pending_request_id;
  uint8_t pending_type;
  int role;
  int hello;
  int retired;
  int failed;
} fs_diag_endpoint;

enum {
  FS_DIAG_ENDPOINT_PARENT = 1,
  FS_DIAG_ENDPOINT_CHILD = 2,
  FS_DIAG_ENDPOINT_EXHAUSTED = 3
};

#ifdef __cplusplus
extern "C" {
#endif

int fs_diag_endpoint_init(fs_diag_endpoint *endpoint, fs_diag_page *page,
                          int role);

// Uses the same bounded chunk contract as diagnostic_protocol. Parent request
// IDs start at 1 for INIT and increase by one. MAX is reserved for final
// RETIRE. A parent cannot start another command until its matching reply is
// consumed. A child must publish exactly one HELLO, then one matching reply per
// command. EXHAUSTED refuses an ordinary command without changing ownership or
// poisoning; the remaining reply sequence is reserved for RETIRED because HELLO
// already used one reply publication.
int fs_diag_endpoint_send(fs_diag_endpoint *endpoint, uint8_t type,
                          uint64_t request_id, uint32_t total_length,
                          const uint8_t *chunk, uint32_t chunk_length);

// COMPLETE exposes metadata in endpoint.receive; partial bytes must not be
// decoded. Body/schema validation is separately required before file authority.
// Any failure permanently poisons both local directions, retaining pending
// ownership for the process owner to settle. Retirement permits no later frame.
int fs_diag_endpoint_receive(fs_diag_endpoint *endpoint, uint8_t *output,
                             uint32_t capacity, uint32_t *copied);

#ifdef __cplusplus
}
#endif
#endif
