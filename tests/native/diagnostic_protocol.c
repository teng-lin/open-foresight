#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_protocol.h"

#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(value)                                                           \
  do {                                                                         \
    if (!(value)) {                                                            \
      fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__,       \
              #value);                                                         \
      abort();                                                                 \
    }                                                                          \
  } while (0)

static void complete_init(fs_diag_page *page, fs_diag_send_cursor *send) {
  static const uint8_t payload[] = {1, 2, 3};
  CHECK(fs_diag_publish(page, FS_DIAG_REQUEST_CHANNEL, send, FS_DIAG_INIT, 1,
                        sizeof(payload), payload,
                        sizeof(payload)) == FS_DIAG_CHANNEL_COMPLETE);
}

static void publish_complete(fs_diag_page *page, int channel,
                             fs_diag_send_cursor *send, uint8_t type,
                             uint64_t id, const uint8_t *bytes,
                             uint32_t length) {
  uint32_t offset = 0;
  do {
    uint32_t count = length - offset;
    if (count > FS_DIAG_CHUNK_BYTES)
      count = FS_DIAG_CHUNK_BYTES;
    int result = fs_diag_publish(page, channel, send, type, id, length,
                                 count ? bytes + offset : NULL, count);
    offset += count;
    CHECK(result == (offset == length ? FS_DIAG_CHANNEL_COMPLETE
                                      : FS_DIAG_CHANNEL_PARTIAL));
  } while (offset != length);
}

static void roundtrip(void) {
  fs_diag_page page = {0};
  fs_diag_send_cursor send = {0};
  fs_diag_receive_cursor receive = {0};
  uint8_t source[FS_DIAG_REQUEST_PAYLOAD];
  uint8_t output[FS_DIAG_REQUEST_PAYLOAD];
  memset(source, 0xb7, sizeof(source));
  CHECK(fs_diag_page_supported(&page));
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                        sizeof(source), source,
                        FS_DIAG_CHUNK_BYTES) == FS_DIAG_CHANNEL_PARTIAL);
  uint32_t copied = 99;
  CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output,
                        FS_DIAG_COPY_LIMIT, &copied) == FS_DIAG_CHANNEL_EMPTY);
  CHECK(copied == 0);
  uint32_t offset = FS_DIAG_CHUNK_BYTES;
  while (offset != sizeof(source)) {
    uint32_t count = sizeof(source) - offset;
    if (count > FS_DIAG_CHUNK_BYTES)
      count = FS_DIAG_CHUNK_BYTES;
    int result =
        fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                        sizeof(source), source + offset, count);
    offset += count;
    CHECK(result == (offset == sizeof(source) ? FS_DIAG_CHANNEL_COMPLETE
                                              : FS_DIAG_CHANNEL_PARTIAL));
  }
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_HEALTH,
                        2, 0, NULL, 0) == FS_DIAG_CHANNEL_EMPTY);
  offset = 0;
  while (offset != sizeof(output)) {
    uint32_t capacity = sizeof(output) - offset;
    if (capacity > FS_DIAG_COPY_LIMIT)
      capacity = FS_DIAG_COPY_LIMIT;
    int result = fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive,
                                 output + offset, capacity, &copied);
    CHECK(copied <= FS_DIAG_CHUNK_BYTES);
    offset += copied;
    CHECK(result == (offset == sizeof(output) ? FS_DIAG_CHANNEL_COMPLETE
                                              : FS_DIAG_CHANNEL_PARTIAL));
    CHECK(atomic_load(&page.header.request_consumed) ==
          (offset == sizeof(output) ? 1 : 0));
  }
  CHECK(memcmp(source, output, sizeof(source)) == 0);
  CHECK(receive.request_id == 1 && receive.type == FS_DIAG_INIT);
  CHECK(atomic_load(&page.header.request_consumed) == 1);
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_RETIRE,
                        FS_DIAG_MAX_SEQUENCE, 0, NULL,
                        0) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output, 1,
                        &copied) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(copied == 0 && receive.request_id == FS_DIAG_MAX_SEQUENCE);
  fs_diag_send_cursor reply = {0};
  fs_diag_receive_cursor read_reply = {0};
  CHECK(fs_diag_publish(&page, FS_DIAG_REPLY_CHANNEL, &reply, FS_DIAG_HELLO, 0,
                        0, NULL, 0) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_receive(&page, FS_DIAG_REPLY_CHANNEL, &read_reply, output, 1,
                        &copied) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(copied == 0 && read_reply.type == FS_DIAG_HELLO);
}

static void malformed(void) {
  for (unsigned fault = 0; fault != 13; ++fault) {
    fs_diag_page page = {0};
    fs_diag_send_cursor send = {0};
    fs_diag_receive_cursor receive = {0};
    complete_init(&page, &send);
    switch (fault) {
    case 0:
      page.request[0] = 'X';
      break;
    case 1:
      page.request[4] = 2;
      break;
    case 2:
      page.request[5] = 255;
      break;
    case 3:
      page.request[6] = 1;
      break;
    case 4:
      page.request[7] = 1;
      break;
    case 5:
      page.request[8] = 0x80;
      break; // Outside positive 63-bit IDs.
    case 6:
      page.request[15] = 0;
      break; // INIT must have ID 1.
    case 7:
      memset(page.request + 16, 255, 4);
      break;
    case 8:
      atomic_store(&page.header.request_published, 2);
      break;
    case 9:
      atomic_store(&page.header.request_consumed, 1);
      break;
    case 10:
      atomic_store(&page.header.request_published, UINT64_MAX);
      break;
    case 11:
      page.request[5] = FS_DIAG_RESULT;
      break;
    case 12:
      atomic_store(&page.header.request_consumed, UINT64_MAX);
      break;
    }
    uint8_t output[8];
    memset(output, 0x6b, sizeof(output));
    uint32_t copied = 99;
    CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output + 1,
                          sizeof(output) - 2,
                          &copied) == FS_DIAG_CHANNEL_ERROR);
    CHECK(copied == 0 && output[0] == 0x6b && output[7] == 0x6b);
    CHECK(receive.failed);
    // Correcting peer bytes cannot unpoison a cursor or authorize a retry.
    memset(page.request, 0, sizeof(page.request));
    CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output + 1,
                          sizeof(output) - 2,
                          &copied) == FS_DIAG_CHANNEL_ERROR);
  }
  fs_diag_page page = {0};
  fs_diag_send_cursor send = {0};
  fs_diag_receive_cursor receive = {0};
  uint8_t first[4096] = {0};
  uint8_t output[4096];
  uint32_t copied;
  uint8_t large[FS_DIAG_REQUEST_PAYLOAD] = {0};
  publish_complete(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                   large, sizeof(large));
  CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output,
                        sizeof(output), &copied) == FS_DIAG_CHANNEL_PARTIAL);
  // Still-valid INIT length 8191 reaches the saved-header comparison rather
  // than failing the outer length bound first.
  page.request[18] = 0x1f;
  page.request[19] = 0xff;
  CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive, output,
                        sizeof(output), &copied) == FS_DIAG_CHANNEL_ERROR);
  CHECK(copied == 0 && atomic_load(&page.header.request_consumed) == 0);
  page = (fs_diag_page){0};
  send = (fs_diag_send_cursor){0};
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                        8192, first,
                        FS_DIAG_CHUNK_BYTES) == FS_DIAG_CHANNEL_PARTIAL);
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                        8191, first,
                        FS_DIAG_CHUNK_BYTES) == FS_DIAG_CHANNEL_ERROR);
  CHECK(atomic_load(&page.header.request_published) == 0);
  page = (fs_diag_page){0};
  send = (fs_diag_send_cursor){0};
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_APPEND,
                        2, 4097, first,
                        FS_DIAG_CHUNK_BYTES) == FS_DIAG_CHANNEL_ERROR);
  send = (fs_diag_send_cursor){0};
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_HEALTH,
                        FS_DIAG_MAX_SEQUENCE, 0, NULL,
                        0) == FS_DIAG_CHANNEL_ERROR);
}

static void publisher_faults(void) {
  uint8_t bytes[8] = {0};
  for (unsigned fault = 0; fault != 7; ++fault) {
    fs_diag_page page = {0};
    fs_diag_send_cursor send = {0};
    switch (fault) {
    case 0:
      atomic_store(&page.header.request_published, 1);
      break;
    case 1:
      atomic_store(&page.header.request_consumed, 1);
      break;
    case 2:
      send.sequence = 2;
      atomic_store(&page.header.request_published, 2);
      break; // Acknowledgement is more than one frame behind.
    case 3:
      CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT,
                            1, 16, bytes,
                            sizeof(bytes)) == FS_DIAG_CHANNEL_PARTIAL);
      atomic_store(&page.header.request_consumed, UINT64_MAX);
      break;
    case 4:
      CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT,
                            1, 16, bytes,
                            sizeof(bytes)) == FS_DIAG_CHANNEL_PARTIAL);
      page.request[6] = 1;
      break;
    case 6:
      complete_init(&page, &send);
      atomic_store(&page.header.request_consumed, 1);
      CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT,
                            1, 16, bytes,
                            sizeof(bytes)) == FS_DIAG_CHANNEL_PARTIAL);
      atomic_store(&page.header.request_consumed, 0);
      break; // A peer rolled back its ACK while a new frame was being copied.
    case 5:
      send.sequence = FS_DIAG_MAX_SEQUENCE;
      atomic_store(&page.header.request_published, FS_DIAG_MAX_SEQUENCE);
      atomic_store(&page.header.request_consumed, FS_DIAG_MAX_SEQUENCE);
      break;
    }
    CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT,
                          1, 16, bytes,
                          sizeof(bytes)) == FS_DIAG_CHANNEL_ERROR);
    CHECK(send.failed);
    page = (fs_diag_page){0};
    CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT,
                          1, 0, NULL, 0) == FS_DIAG_CHANNEL_ERROR);
    CHECK(atomic_load(&page.header.request_published) == 0);
  }
  fs_diag_page page = {0};
  fs_diag_send_cursor send = {0};
  uint8_t oversized_chunk[4057] = {0};
  CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                        8192, oversized_chunk,
                        sizeof(oversized_chunk)) == FS_DIAG_CHANNEL_ERROR);
  CHECK(atomic_load(&page.header.request_published) == 0);
}

static void reply_and_copy_bounds(void) {
  uint8_t payload[FS_DIAG_COPY_LIMIT] = {0};
  for (unsigned fault = 0; fault != 6; ++fault) {
    fs_diag_page page = {0};
    fs_diag_send_cursor send = {0};
    fs_diag_receive_cursor receive = {0};
    CHECK(fs_diag_publish(&page, FS_DIAG_REPLY_CHANNEL, &send, FS_DIAG_HELLO, 0,
                          512, payload, 512) == FS_DIAG_CHANNEL_COMPLETE);
    switch (fault) {
    case 0:
      page.reply[15] = 1;
      break; // HELLO ID must be zero.
    case 1:
      page.reply[5] = FS_DIAG_RESULT;
      break; // RESULT ID cannot be zero.
    case 2:
      page.reply[5] = FS_DIAG_RETIRED;
      page.reply[15] = 1;
      break;
    case 3:
      page.reply[5] = FS_DIAG_INIT;
      page.reply[15] = 1;
      break;
    case 4:
      page.reply[19] = 1;
      break; // 513 bytes cannot fit the reply cell.
    case 5:
      break; // Exact 512-byte boundary is accepted.
    }
    uint8_t output[514];
    memset(output, 0x6b, sizeof(output));
    uint32_t copied = 99;
    int result = fs_diag_receive(&page, FS_DIAG_REPLY_CHANNEL, &receive,
                                 output + 1, 512, &copied);
    CHECK(result ==
          (fault == 5 ? FS_DIAG_CHANNEL_COMPLETE : FS_DIAG_CHANNEL_ERROR));
    CHECK(copied == (fault == 5 ? 512 : 0));
    CHECK(output[0] == 0x6b && output[513] == 0x6b);
  }
  for (unsigned extra = 0; extra != 2; ++extra) {
    fs_diag_page page = {0};
    fs_diag_send_cursor send = {0};
    fs_diag_receive_cursor receive = {0};
    publish_complete(&page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_APPEND, 2,
                     payload, sizeof(payload));
    if (extra)
      page.request[19] = 1;
    uint8_t output[4098];
    memset(output, 0x6b, sizeof(output));
    uint32_t copied = 99;
    int result = fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive,
                                 output + 1, 4096, &copied);
    CHECK(result == (extra ? FS_DIAG_CHANNEL_ERROR : FS_DIAG_CHANNEL_PARTIAL));
    CHECK(copied == (extra ? 0 : FS_DIAG_CHUNK_BYTES));
    if (!extra) {
      uint32_t offset = copied;
      CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive,
                            output + 1 + offset, 4096 - offset,
                            &copied) == FS_DIAG_CHANNEL_COMPLETE);
      CHECK(offset + copied == 4096);
    }
    CHECK(output[0] == 0x6b && output[4097] == 0x6b);
  }
  for (unsigned fault = 0; fault != 5; ++fault) {
    fs_diag_page page = {0};
    fs_diag_send_cursor send = {0};
    fs_diag_receive_cursor receive = {0};
    complete_init(&page, &send);
    uint32_t copied = 99;
    uint32_t capacity = fault == 0 ? 0 : fault == 1 ? 4097 : 8;
    if (fault == 4)
      receive.sequence = FS_DIAG_MAX_SEQUENCE;
    CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive,
                          fault == 2 ? NULL : payload, capacity,
                          fault == 3 ? NULL : &copied) ==
          FS_DIAG_CHANNEL_ERROR);
    CHECK(receive.failed && (fault == 3 || copied == 0));
  }
}

// A protected local copy buffer supplies an exact, deterministic interruption
// during memcpy without adding a production hook. The test handler changes the
// peer-owned shared bytes and permits that copy to resume. This is a component
// consistency control, not a claim to authenticate concurrent malicious writes.
static fs_diag_page *fault_page;
static void *fault_buffer;
static size_t fault_size;
static volatile sig_atomic_t fault_kind;
static volatile sig_atomic_t fault_observed;

static void copy_fault(int signal, siginfo_t *info, void *context) {
  (void)context;
  uintptr_t address = (uintptr_t)info->si_addr;
  if ((signal != SIGSEGV && signal != SIGBUS) ||
      address < (uintptr_t)fault_buffer ||
      address >= (uintptr_t)fault_buffer + fault_size || fault_observed)
    _exit(91);
  fault_observed = 1;
  if (fault_kind == 1)
    atomic_store_explicit(&fault_page->header.request_consumed, 1,
                          memory_order_release);
  else if (fault_kind == 2)
    fault_page->request[6] = 1;
  else
    atomic_store_explicit(&fault_page->header.request_published, 2,
                          memory_order_release);
  if (mprotect(fault_buffer, fault_size, PROT_READ | PROT_WRITE) != 0)
    _exit(92);
}

static void interrupted_copy(void) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(5);
    fault_size = (size_t)sysconf(_SC_PAGESIZE);
    fault_buffer = mmap(NULL, fault_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(fault_buffer != MAP_FAILED);
    memset(fault_buffer, 0, fault_size);
    struct sigaction handler = {0};
    handler.sa_sigaction = copy_fault;
    handler.sa_flags = SA_SIGINFO;
    sigemptyset(&handler.sa_mask);
    CHECK(sigaction(SIGSEGV, &handler, NULL) == 0);
    CHECK(sigaction(SIGBUS, &handler, NULL) == 0);
    for (fault_kind = 1; fault_kind != 4; ++fault_kind) {
      fs_diag_page page = {0};
      fs_diag_send_cursor send = {0};
      fs_diag_receive_cursor receive = {0};
      fault_page = &page;
      fault_observed = 0;
      if (fault_kind == 1) {
        CHECK(mprotect(fault_buffer, fault_size, PROT_NONE) == 0);
        CHECK(fs_diag_publish(&page, FS_DIAG_REQUEST_CHANNEL, &send,
                              FS_DIAG_INIT, 1, 8, fault_buffer,
                              8) == FS_DIAG_CHANNEL_ERROR);
        CHECK(send.failed && atomic_load(&page.header.request_published) == 0);
      } else {
        complete_init(&page, &send);
        CHECK(mprotect(fault_buffer, fault_size, PROT_READ) == 0);
        uint32_t copied = 99;
        CHECK(fs_diag_receive(&page, FS_DIAG_REQUEST_CHANNEL, &receive,
                              fault_buffer, 8,
                              &copied) == FS_DIAG_CHANNEL_ERROR);
        CHECK(receive.failed && copied == 0 &&
              atomic_load(&page.header.request_consumed) == 0);
      }
      CHECK(fault_observed);
    }
    CHECK(munmap(fault_buffer, fault_size) == 0);
    _exit(0);
  }
  int status;
  CHECK(waitpid(child, &status, 0) == child);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void cross_process(void) {
  // Guard pages detect escapes from the entire fixed page. Per-cell bounds and
  // output canaries are checked separately; these guards do not divide cells.
  long size = sysconf(_SC_PAGESIZE);
  CHECK(size > 0 && size <= FS_DIAG_PAGE_BYTES);
  size_t allocation = FS_DIAG_PAGE_BYTES + 2 * (size_t)size;
  uint8_t *mapping =
      mmap(NULL, allocation, PROT_NONE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  CHECK(mapping != MAP_FAILED);
  fs_diag_page *page = (fs_diag_page *)(mapping + size);
  CHECK(mprotect(page, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE) == 0);
  memset(page, 0, sizeof(*page));
  CHECK(fs_diag_page_supported(page));
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(10);
    fs_diag_receive_cursor receive = {0};
    fs_diag_send_cursor send = {0};
    uint8_t initial[FS_DIAG_REQUEST_PAYLOAD];
    uint32_t initial_offset = 0;
    while (initial_offset != sizeof(initial)) {
      uint32_t copied;
      uint32_t capacity = sizeof(initial) - initial_offset;
      if (capacity > FS_DIAG_COPY_LIMIT)
        capacity = FS_DIAG_COPY_LIMIT;
      int result = fs_diag_receive(page, FS_DIAG_REQUEST_CHANNEL, &receive,
                                   initial + initial_offset, capacity, &copied);
      CHECK(result != FS_DIAG_CHANNEL_ERROR);
      initial_offset += copied;
      if (result == FS_DIAG_CHANNEL_EMPTY)
        sched_yield();
      else
        CHECK(result == (initial_offset == sizeof(initial)
                             ? FS_DIAG_CHANNEL_COMPLETE
                             : FS_DIAG_CHANNEL_PARTIAL));
    }
    for (unsigned i = 0; i != sizeof(initial); ++i)
      CHECK(initial[i] == 0xb7);
    CHECK(receive.request_id == 1 && receive.type == FS_DIAG_INIT);
    uint8_t initial_reply[FS_DIAG_REPLY_PAYLOAD];
    memset(initial_reply, 0x5e, sizeof(initial_reply));
    publish_complete(page, FS_DIAG_REPLY_CHANNEL, &send, FS_DIAG_RESULT, 1,
                     initial_reply, sizeof(initial_reply));
    for (unsigned n = 0; n != 1000; ++n) {
      uint8_t bytes[8];
      uint32_t copied;
      int status;
      while ((status = fs_diag_receive(page, FS_DIAG_REQUEST_CHANNEL, &receive,
                                       bytes, sizeof(bytes), &copied)) == 0)
        sched_yield();
      CHECK(status == FS_DIAG_CHANNEL_COMPLETE && copied == sizeof(bytes));
      CHECK(receive.request_id == (uint64_t)n + 2 && bytes[0] == (uint8_t)n);
      CHECK(fs_diag_publish(page, FS_DIAG_REPLY_CHANNEL, &send, FS_DIAG_RESULT,
                            receive.request_id, sizeof(bytes), bytes,
                            sizeof(bytes)) == FS_DIAG_CHANNEL_COMPLETE);
    }
    _exit(0);
  }
  alarm(10);
  fs_diag_send_cursor send = {0};
  fs_diag_receive_cursor receive = {0};
  uint8_t initial[FS_DIAG_REQUEST_PAYLOAD];
  memset(initial, 0xb7, sizeof(initial));
  publish_complete(page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_INIT, 1,
                   initial, sizeof(initial));
  uint8_t initial_reply[FS_DIAG_REPLY_PAYLOAD + 2];
  memset(initial_reply, 0x6b, sizeof(initial_reply));
  uint32_t initial_copied;
  int initial_status;
  while ((initial_status = fs_diag_receive(
              page, FS_DIAG_REPLY_CHANNEL, &receive, initial_reply + 1,
              FS_DIAG_REPLY_PAYLOAD, &initial_copied)) == FS_DIAG_CHANNEL_EMPTY)
    sched_yield();
  CHECK(initial_status == FS_DIAG_CHANNEL_COMPLETE &&
        initial_copied == FS_DIAG_REPLY_PAYLOAD);
  CHECK(initial_reply[0] == 0x6b &&
        initial_reply[sizeof(initial_reply) - 1] == 0x6b);
  for (unsigned i = 1; i <= FS_DIAG_REPLY_PAYLOAD; ++i)
    CHECK(initial_reply[i] == 0x5e);
  for (unsigned n = 0; n != 1000; ++n) {
    uint8_t bytes[8] = {(uint8_t)n, 0, 1, 2, 3, 4, 5, 6};
    CHECK(fs_diag_publish(page, FS_DIAG_REQUEST_CHANNEL, &send, FS_DIAG_HEALTH,
                          (uint64_t)n + 2, sizeof(bytes), bytes,
                          sizeof(bytes)) == FS_DIAG_CHANNEL_COMPLETE);
    uint8_t output[8];
    uint32_t copied;
    int status;
    while ((status = fs_diag_receive(page, FS_DIAG_REPLY_CHANNEL, &receive,
                                     output, sizeof(output), &copied)) == 0)
      sched_yield();
    CHECK(status == FS_DIAG_CHANNEL_COMPLETE && copied == sizeof(output));
    CHECK(receive.request_id == (uint64_t)n + 2);
    CHECK(memcmp(output, bytes, sizeof(output)) == 0);
  }
  int status;
  CHECK(waitpid(child, &status, 0) == child);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  alarm(0);
  CHECK(munmap(mapping, allocation) == 0);
}

extern int fs_diag_cpp_header_contract(void);

int main(void) {
  CHECK(fs_diag_cpp_header_contract());
  roundtrip();
  malformed();
  publisher_faults();
  reply_and_copy_bounds();
  interrupted_copy();
  cross_process();
  puts("diagnostic protocol: bounds, malformed frames, partial copies, 1000 "
       "cross-process exchanges passed");
  return 0;
}
