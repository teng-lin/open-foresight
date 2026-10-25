#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Additive diagnostic ABI 1. No Domain/model/capture handles or pointers are
 * retained. The runtime owner must pin its already loaded original image until
 * close returns. One consumer may be open per process; tokens are never reused.
 * All operations try once and return; callers must retry BUSY on a later tick.
 */
enum {
  FS_DIAGNOSTIC_ABI = 1,
  FS_DIAGNOSTIC_OK = 0,
  FS_DIAGNOSTIC_INVALID = -1,
  FS_DIAGNOSTIC_BUSY = -2,
  FS_DIAGNOSTIC_UNAVAILABLE = -3,
  FS_DIAGNOSTIC_PRIORITY_ONLY = 1,
  FS_DIAGNOSTIC_PRECISION_LOST = 1,
  FS_DIAGNOSTIC_COUNTER_SATURATED = 2,
  FS_DIAGNOSTIC_WORKER_FAILED = 1,
  FS_DIAGNOSTIC_CAPTURE_STATE = 2,
};

/* Closed values use the DiagnosticCategory/Outcome/Component enum order in the
 * Dart diagnostic catalog, independently validated again by the consumer.
 * Failed-worker: component=native, queued/active/duration_us=0.
 * Capture-state: component=capture, status/signal/bytes/dropped=0, active<=1.
 * There are no strings, addresses, identities or arbitrary payloads. */
typedef struct fs_diagnostic_record {
  uint64_t sequence;
  uint64_t monotonic_us;
  uint16_t event;
  uint16_t component;
  uint16_t category;
  uint16_t outcome;
  int32_t status;
  int32_t signal;
  uint64_t bytes;
  uint64_t dropped;
  uint32_t queued;
  uint32_t active;
  uint64_t duration_us;
} fs_diagnostic_record;

typedef struct fs_diagnostic_batch {
  uint32_t abi_version;
  uint32_t structure_size;
  uint32_t count;
  uint32_t flags;
  uint64_t dropped_general;
  uint64_t dropped_priority;
} fs_diagnostic_batch;

uint32_t fs_diagnostic_abi_version(void);
/* open writes token only on success; INVALID includes mismatched ABI/size. */
int32_t fs_diagnostic_open(uint32_t abi_version, uint32_t record_size,
                           uint64_t *token);
/* Caller-owned output: capacity 1..64 (at most 4096 bytes of records). On
 * success batch reports exact records, saturating lower-bound drop counts and
 * any precision loss since the last successful drain. No partial records.
 * Priority-only deliberately leaves ordinary records queued; subsequent
 * ordinary drains retain global sequence order among their remaining records.
 * Consumers validate increasing sequence PER LANE: a later ordinary drain may
 * return older records than an earlier priority-only drain. These are native
 * admission sequences, not the globally increasing final writer sequence.
 * INVALID/BUSY leave all caller-owned outputs and queued state unchanged. */
int32_t fs_diagnostic_drain(uint64_t token, uint32_t abi_version,
                            uint32_t record_size, fs_diagnostic_record *records,
                            uint32_t capacity, uint32_t flags,
                            fs_diagnostic_batch *batch, uint32_t batch_size);
int32_t fs_diagnostic_close(uint64_t token);

#ifdef __cplusplus
}

namespace foresight::diagnostics {
enum class Level : uint8_t { off, error, warn, info, debug, trace };
/* Called only while installing the runtime's sealed configuration, before
 * native handles start. The integration owns seal/replay validation. */
void configure(Level level) noexcept;
/* These trusted producers choose the registered event, component and priority.
 * Invalid closed enums or irrelevant fields are rejected before queue access.
 * false means filtered/rejected/dropped; logging never changes business work.
 */
bool worker_failed(uint16_t category, uint16_t outcome, int32_t status,
                   int32_t signal, uint64_t bytes = 0,
                   uint64_t dropped = 0) noexcept;
bool capture_state(uint16_t category, uint16_t outcome, uint32_t queued,
                   bool active, uint64_t duration_us = 0) noexcept;
} // namespace foresight::diagnostics
#endif
