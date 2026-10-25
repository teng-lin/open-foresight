#include "diagnostic_protocol.h"

#include <string.h>
#include <unistd.h>

typedef struct channel_view {
  uint8_t *cell;
  uint32_t limit;
  fs_diag_atomic64 *published;
  fs_diag_atomic64 *consumed;
} channel_view;

static int view(fs_diag_page *page, int channel, channel_view *out) {
  if (page == NULL || out == NULL)
    return 0;
  if (channel == FS_DIAG_REQUEST_CHANNEL) {
    *out = (channel_view){page->request, FS_DIAG_REQUEST_PAYLOAD,
                          &page->header.request_published,
                          &page->header.request_consumed};
    return 1;
  }
  if (channel == FS_DIAG_REPLY_CHANNEL) {
    *out = (channel_view){page->reply, FS_DIAG_REPLY_PAYLOAD,
                          &page->header.reply_published,
                          &page->header.reply_consumed};
    return 1;
  }
  return 0;
}

static uint64_t read64(const uint8_t *p) {
  uint64_t value = 0;
  for (unsigned i = 0; i != 8; ++i)
    value = (value << 8) | p[i];
  return value;
}

static uint32_t read32(const uint8_t *p) {
  uint32_t value = 0;
  for (unsigned i = 0; i != 4; ++i)
    value = (value << 8) | p[i];
  return value;
}

static void write64(uint8_t *p, uint64_t value) {
  for (unsigned i = 8; i != 0; --i) {
    p[i - 1] = (uint8_t)value;
    value >>= 8;
  }
}

static void write32(uint8_t *p, uint32_t value) {
  for (unsigned i = 4; i != 0; --i) {
    p[i - 1] = (uint8_t)value;
    value >>= 8;
  }
}

static int valid(int channel, uint8_t type, uint64_t id, uint32_t length) {
  if (id > FS_DIAG_MAX_SEQUENCE)
    return 0;
  if (channel == FS_DIAG_REPLY_CHANNEL) {
    if (length > FS_DIAG_REPLY_PAYLOAD)
      return 0;
    return (type == FS_DIAG_HELLO && id == 0) ||
           (type == FS_DIAG_RESULT && id >= 1) ||
           (type == FS_DIAG_RETIRED && id >= 2);
  }
  if (channel != FS_DIAG_REQUEST_CHANNEL || length > FS_DIAG_REQUEST_PAYLOAD)
    return 0;
  if (type == FS_DIAG_INIT)
    return id == 1;
  if (id < 2)
    return 0;
  if (type == FS_DIAG_RETIRE)
    return 1;
  if (id == FS_DIAG_MAX_SEQUENCE)
    return 0; // Reserved for final retirement.
  if (type == FS_DIAG_APPEND)
    return length <= FS_DIAG_COPY_LIMIT;
  return type == FS_DIAG_ADMIT || type == FS_DIAG_CLASSIFY ||
         type == FS_DIAG_HEALTH;
}

int fs_diag_page_supported(const fs_diag_page *page) {
  if (page == NULL)
    return 0;
  long size = sysconf(_SC_PAGESIZE);
  return size > 0 && size <= FS_DIAG_PAGE_BYTES &&
         FS_DIAG_PAGE_BYTES % size == 0 &&
         atomic_is_lock_free(&page->header.request_published) &&
         atomic_is_lock_free(&page->header.request_consumed) &&
         atomic_is_lock_free(&page->header.reply_published) &&
         atomic_is_lock_free(&page->header.reply_consumed) &&
         atomic_is_lock_free(&page->header.control_command) &&
         atomic_is_lock_free(&page->header.control_ack) &&
         atomic_is_lock_free(&page->header.child_pid) &&
         atomic_is_lock_free(&page->header.parent_heartbeat) &&
         atomic_is_lock_free(&page->header.child_heartbeat) &&
         atomic_is_lock_free(&page->header.state);
}

int fs_diag_publish(fs_diag_page *page, int channel,
                    fs_diag_send_cursor *cursor, uint8_t type,
                    uint64_t request_id, uint32_t total_length,
                    const uint8_t *chunk, uint32_t chunk_length) {
  channel_view v;
  if (cursor == NULL)
    return FS_DIAG_CHANNEL_ERROR;
  if (cursor->failed)
    return FS_DIAG_CHANNEL_ERROR;
  if (!view(page, channel, &v) || chunk_length > FS_DIAG_CHUNK_BYTES ||
      (chunk_length != 0 && chunk == NULL) ||
      (total_length != 0 && chunk_length == 0) ||
      !valid(channel, type, request_id, total_length) ||
      cursor->sequence >= FS_DIAG_MAX_SEQUENCE)
    goto broken;
  uint64_t published = atomic_load_explicit(v.published, memory_order_acquire);
  uint64_t consumed = atomic_load_explicit(v.consumed, memory_order_acquire);
  if (published != cursor->sequence || consumed > published)
    goto broken;
  if (consumed != published) {
    if (cursor->pending || published == 0 || consumed != published - 1)
      goto broken;
    return FS_DIAG_CHANNEL_EMPTY; // The one preceding frame is still owned.
  }
  uint8_t frame[FS_DIAG_FRAME_BYTES] = {
      'O', 'F', 'D', 'P', FS_DIAG_PROTOCOL_VERSION, type, 0, 0};
  write64(frame + 8, request_id);
  write32(frame + 16, total_length);
  if (!cursor->pending) {
    cursor->pending = 1;
    cursor->request_id = request_id;
    cursor->type = type;
    cursor->length = total_length;
    cursor->copied = 0;
    memcpy(v.cell, frame, sizeof(frame));
  } else if (cursor->request_id != request_id || cursor->type != type ||
             cursor->length != total_length ||
             memcmp(v.cell, frame, sizeof(frame)) != 0)
    goto broken;
  if (cursor->copied > total_length ||
      chunk_length > total_length - cursor->copied)
    goto broken;
  if (chunk_length != 0)
    memcpy(v.cell + sizeof(frame) + cursor->copied, chunk, chunk_length);
  // Keep local copies before the consistency observations on ARM64 too. This
  // detects observed changes, not malicious ABA or authenticated payload bytes.
  atomic_thread_fence(memory_order_seq_cst);
  if (atomic_load_explicit(v.published, memory_order_acquire) != published ||
      atomic_load_explicit(v.consumed, memory_order_acquire) != consumed)
    goto broken;
  cursor->copied += chunk_length;
  if (cursor->copied != total_length)
    return FS_DIAG_CHANNEL_PARTIAL;
  cursor->pending = 0;
  atomic_store_explicit(v.published, ++cursor->sequence, memory_order_release);
  return FS_DIAG_CHANNEL_COMPLETE;
broken:
  cursor->failed = 1;
  return FS_DIAG_CHANNEL_ERROR;
}

int fs_diag_receive(fs_diag_page *page, int channel,
                    fs_diag_receive_cursor *cursor, uint8_t *output,
                    uint32_t capacity, uint32_t *copied) {
  channel_view v;
  if (copied != NULL)
    *copied = 0;
  if (cursor == NULL)
    return FS_DIAG_CHANNEL_ERROR;
  if (cursor->failed)
    return FS_DIAG_CHANNEL_ERROR;
  if (!view(page, channel, &v) || output == NULL || copied == NULL ||
      capacity == 0 || capacity > FS_DIAG_COPY_LIMIT ||
      cursor->sequence >= FS_DIAG_MAX_SEQUENCE)
    goto broken;
  uint64_t sequence = atomic_load_explicit(v.published, memory_order_acquire);
  if (atomic_load_explicit(v.consumed, memory_order_acquire) !=
      cursor->sequence)
    goto broken;
  if (sequence == cursor->sequence && cursor->pending_sequence == 0)
    return FS_DIAG_CHANNEL_EMPTY;
  if (sequence != cursor->sequence + 1)
    goto broken;
  uint8_t frame[FS_DIAG_FRAME_BYTES];
  memcpy(frame, v.cell, sizeof(frame));
  if (memcmp(frame, "OFDP", 4) != 0 || frame[4] != FS_DIAG_PROTOCOL_VERSION ||
      frame[6] != 0 || frame[7] != 0)
    goto broken;
  uint64_t id = read64(frame + 8);
  uint32_t length = read32(frame + 16);
  if (!valid(channel, frame[5], id, length) || length > v.limit)
    goto broken;
  if (cursor->pending_sequence == 0) {
    cursor->pending_sequence = sequence;
    cursor->request_id = id;
    cursor->length = length;
    cursor->copied = 0;
    cursor->type = frame[5];
    memcpy(cursor->frame, frame, sizeof(frame));
  } else if (cursor->pending_sequence != sequence ||
             memcmp(cursor->frame, frame, sizeof(frame)) != 0)
    goto broken;
  if (cursor->copied > length)
    goto broken;
  uint32_t count = length - cursor->copied;
  if (count > capacity)
    count = capacity;
  if (count > FS_DIAG_CHUNK_BYTES)
    count = FS_DIAG_CHUNK_BYTES;
  if (count != 0)
    memcpy(output, v.cell + FS_DIAG_FRAME_BYTES + cursor->copied, count);
  atomic_thread_fence(memory_order_seq_cst);
  if (atomic_load_explicit(v.published, memory_order_acquire) != sequence ||
      atomic_load_explicit(v.consumed, memory_order_acquire) !=
          cursor->sequence ||
      memcmp(frame, v.cell, sizeof(frame)) != 0)
    goto broken;
  cursor->copied += count;
  *copied = count;
  if (cursor->copied != length)
    return FS_DIAG_CHANNEL_PARTIAL;
  cursor->sequence = sequence;
  cursor->pending_sequence = 0;
  atomic_store_explicit(v.consumed, sequence, memory_order_release);
  return FS_DIAG_CHANNEL_COMPLETE;
broken:
  cursor->failed = 1;
  return FS_DIAG_CHANNEL_ERROR;
}
