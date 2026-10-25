#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_endpoint.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHECK(value)                                                           \
  do {                                                                         \
    if (!(value)) {                                                            \
      fprintf(stderr, "check failed %s:%d: %s\n", __FILE__, __LINE__, #value); \
      abort();                                                                 \
    }                                                                          \
  } while (0)

typedef struct pair {
  fs_diag_page page;
  fs_diag_endpoint parent;
  fs_diag_endpoint child;
} pair;

static void fresh(pair *value) {
  memset(value, 0, sizeof(*value));
  CHECK(fs_diag_endpoint_init(&value->parent, &value->page,
                              FS_DIAG_ENDPOINT_PARENT) ==
        FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_endpoint_init(&value->child, &value->page,
                              FS_DIAG_ENDPOINT_CHILD) ==
        FS_DIAG_CHANNEL_COMPLETE);
}

static void send_frame(fs_diag_endpoint *endpoint, uint8_t type, uint64_t id,
                       const uint8_t *bytes, uint32_t length) {
  uint32_t offset = 0;
  do {
    uint32_t count = length - offset;
    if (count > FS_DIAG_CHUNK_BYTES)
      count = FS_DIAG_CHUNK_BYTES;
    int result = fs_diag_endpoint_send(endpoint, type, id, length,
                                       count ? bytes + offset : NULL, count);
    offset += count;
    CHECK(result == (offset == length ? FS_DIAG_CHANNEL_COMPLETE
                                      : FS_DIAG_CHANNEL_PARTIAL));
  } while (offset != length);
}

static void receive_frame(fs_diag_endpoint *endpoint, uint8_t *bytes,
                          uint32_t length) {
  uint32_t offset = 0;
  int result;
  do {
    uint32_t copied = 0;
    uint32_t capacity = length - offset;
    if (capacity == 0)
      capacity = 1;
    if (capacity > FS_DIAG_CHUNK_BYTES)
      capacity = FS_DIAG_CHUNK_BYTES;
    result =
        fs_diag_endpoint_receive(endpoint, bytes + offset, capacity, &copied);
    CHECK(result >= FS_DIAG_CHANNEL_EMPTY);
    CHECK(copied <= length - offset);
    offset += copied;
    CHECK(result == FS_DIAG_CHANNEL_COMPLETE || offset < length || length == 0);
    if (result == FS_DIAG_CHANNEL_EMPTY) {
      const struct timespec delay = {.tv_nsec = 1000000};
      CHECK(nanosleep(&delay, NULL) == 0);
    }
  } while (result != FS_DIAG_CHANNEL_COMPLETE);
  CHECK(offset == length);
}

static void hello(pair *value) {
  uint8_t buffer[1];
  send_frame(&value->child, FS_DIAG_HELLO, 0, NULL, 0);
  receive_frame(&value->parent, buffer, 0);
  CHECK(value->parent.hello && value->child.hello);
}

static void poison_asserted(fs_diag_endpoint *endpoint) {
  CHECK(endpoint->failed && endpoint->send.failed && endpoint->receive.failed);
  CHECK(fs_diag_endpoint_send(endpoint, FS_DIAG_INIT, 1, 0, NULL, 0) ==
        FS_DIAG_CHANNEL_ERROR);
  uint8_t bytes[1];
  uint32_t copied = 99;
  CHECK(fs_diag_endpoint_receive(endpoint, bytes, sizeof(bytes), &copied) ==
        FS_DIAG_CHANNEL_ERROR);
  CHECK(copied == 0);
}

static void lifecycle(void) {
  pair value;
  fresh(&value);
  hello(&value);
  uint8_t source[FS_DIAG_REQUEST_PAYLOAD], output[FS_DIAG_REQUEST_PAYLOAD];
  memset(source, 0x37, sizeof(source));
  send_frame(&value.parent, FS_DIAG_INIT, 1, source, sizeof(source));
  CHECK(value.parent.pending_request_id == 1);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_APPEND, 2, 0, NULL, 0) ==
        FS_DIAG_CHANNEL_EMPTY);
  receive_frame(&value.child, output, sizeof(output));
  CHECK(memcmp(source, output, sizeof(source)) == 0);
  CHECK(value.child.pending_request_id == 1);
  send_frame(&value.child, FS_DIAG_RESULT, 1, source, FS_DIAG_REPLY_PAYLOAD);
  receive_frame(&value.parent, output, FS_DIAG_REPLY_PAYLOAD);
  CHECK(memcmp(source, output, FS_DIAG_REPLY_PAYLOAD) == 0);
  CHECK(value.parent.pending_request_id == 0 &&
        value.parent.next_request_id == 2);
  send_frame(&value.parent, FS_DIAG_APPEND, 2, source, FS_DIAG_COPY_LIMIT);
  receive_frame(&value.child, output, FS_DIAG_COPY_LIMIT);
  CHECK(memcmp(source, output, FS_DIAG_COPY_LIMIT) == 0);
  send_frame(&value.child, FS_DIAG_RESULT, 2, NULL, 0);
  receive_frame(&value.parent, output, 0);
  send_frame(&value.parent, FS_DIAG_RETIRE, FS_DIAG_MAX_SEQUENCE, NULL, 0);
  receive_frame(&value.child, output, 0);
  send_frame(&value.child, FS_DIAG_RETIRED, FS_DIAG_MAX_SEQUENCE, NULL, 0);
  receive_frame(&value.parent, output, 0);
  CHECK(value.parent.retired && value.child.retired);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_HEALTH, 3, 0, NULL, 0) ==
        FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);
}

static void malformed(void) {
  pair value;
  uint8_t output[1];
  uint32_t copied;
  fresh(&value);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_INIT, 1, 0, NULL, 0) ==
        FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);

  fresh(&value);
  CHECK(fs_diag_publish(&value.page, FS_DIAG_REPLY_CHANNEL, &value.child.send,
                        FS_DIAG_RESULT, 1, 0, NULL,
                        0) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_endpoint_receive(&value.parent, output, sizeof(output),
                                 &copied) == FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);

  fresh(&value);
  hello(&value);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_APPEND, 2, 0, NULL, 0) ==
        FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);

  fresh(&value);
  hello(&value);
  send_frame(&value.parent, FS_DIAG_INIT, 1, NULL, 0);
  receive_frame(&value.child, output, 0);
  CHECK(fs_diag_publish(&value.page, FS_DIAG_REPLY_CHANNEL, &value.child.send,
                        FS_DIAG_RESULT, 2, 0, NULL,
                        0) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_endpoint_receive(&value.parent, output, sizeof(output),
                                 &copied) == FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);

  fresh(&value);
  hello(&value);
  send_frame(&value.parent, FS_DIAG_INIT, 1, NULL, 0);
  receive_frame(&value.child, output, 0);
  send_frame(&value.child, FS_DIAG_RESULT, 1, NULL, 0);
  receive_frame(&value.parent, output, 0);
  CHECK(fs_diag_publish(&value.page, FS_DIAG_REQUEST_CHANNEL,
                        &value.parent.send, FS_DIAG_INIT, 1, 0, NULL,
                        0) == FS_DIAG_CHANNEL_COMPLETE);
  CHECK(fs_diag_endpoint_receive(&value.child, output, sizeof(output),
                                 &copied) == FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.child);

  fresh(&value);
  hello(&value);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_INIT, 1, 1, NULL, 1) ==
        FS_DIAG_CHANNEL_ERROR);
  poison_asserted(&value.parent);
}

static void seed_near_exhaustion(pair *value, uint64_t next) {
  fresh(value);
  hello(value);
  uint8_t output[1];
  send_frame(&value->parent, FS_DIAG_INIT, 1, NULL, 0);
  receive_frame(&value->child, output, 0);
  send_frame(&value->child, FS_DIAG_RESULT, 1, NULL, 0);
  receive_frame(&value->parent, output, 0);
  // Coherent state after next-1 completed requests, plus the original HELLO.
  // Reach the actual 63-bit boundary without a centuries-long loop.
  value->parent.next_request_id = value->child.next_request_id = next;
  value->parent.send.sequence = value->child.receive.sequence = next - 1;
  value->child.send.sequence = value->parent.receive.sequence = next;
  atomic_store(&value->page.header.request_published, next - 1);
  atomic_store(&value->page.header.request_consumed, next - 1);
  atomic_store(&value->page.header.reply_published, next);
  atomic_store(&value->page.header.reply_consumed, next);
}

static void exhaustion(void) {
  pair value;
  seed_near_exhaustion(&value, FS_DIAG_MAX_SEQUENCE - 2);
  uint8_t output[1];
  send_frame(&value.parent, FS_DIAG_HEALTH, FS_DIAG_MAX_SEQUENCE - 2, NULL, 0);
  receive_frame(&value.child, output, 0);
  send_frame(&value.child, FS_DIAG_RESULT, FS_DIAG_MAX_SEQUENCE - 2, NULL, 0);
  receive_frame(&value.parent, output, 0);
  CHECK(fs_diag_endpoint_send(&value.parent, FS_DIAG_HEALTH,
                              FS_DIAG_MAX_SEQUENCE - 1, 0, NULL,
                              0) == FS_DIAG_ENDPOINT_EXHAUSTED);
  CHECK(!value.parent.failed && value.parent.pending_request_id == 0);
  CHECK(value.parent.send.sequence == FS_DIAG_MAX_SEQUENCE - 2);
  send_frame(&value.parent, FS_DIAG_RETIRE, FS_DIAG_MAX_SEQUENCE, NULL, 0);
  receive_frame(&value.child, output, 0);
  send_frame(&value.child, FS_DIAG_RETIRED, FS_DIAG_MAX_SEQUENCE, NULL, 0);
  receive_frame(&value.parent, output, 0);
  CHECK(value.child.send.sequence == FS_DIAG_MAX_SEQUENCE);
  CHECK(value.parent.receive.sequence == FS_DIAG_MAX_SEQUENCE);
  CHECK(value.child.retired && value.parent.retired);

  seed_near_exhaustion(&value, FS_DIAG_MAX_SEQUENCE - 1);
  CHECK(fs_diag_publish(&value.page, FS_DIAG_REQUEST_CHANNEL,
                        &value.parent.send, FS_DIAG_HEALTH,
                        FS_DIAG_MAX_SEQUENCE - 1, 0, NULL,
                        0) == FS_DIAG_CHANNEL_COMPLETE);
  uint32_t copied = 99;
  CHECK(fs_diag_endpoint_receive(&value.child, output, sizeof(output),
                                 &copied) == FS_DIAG_CHANNEL_ERROR);
  CHECK(copied == 0);
  poison_asserted(&value.child);
}

static void cross_process(void) {
  fs_diag_page *page = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_ANON, -1, 0);
  CHECK(page != MAP_FAILED);
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(10); // fork does not inherit the parent's alarm deadline.
    fs_diag_endpoint endpoint;
    CHECK(fs_diag_endpoint_init(&endpoint, page, FS_DIAG_ENDPOINT_CHILD) ==
          FS_DIAG_CHANNEL_COMPLETE);
    uint8_t bytes[3];
    send_frame(&endpoint, FS_DIAG_HELLO, 0, NULL, 0);
    for (uint64_t id = 1; id != 4; ++id) {
      receive_frame(&endpoint, bytes, id == 3 ? 0 : sizeof(bytes));
      CHECK(endpoint.pending_request_id == id);
      CHECK(endpoint.pending_type == (id == 1   ? FS_DIAG_INIT
                                      : id == 2 ? FS_DIAG_APPEND
                                                : FS_DIAG_RETIRE));
      if (id != 3)
        CHECK(memcmp(bytes, "abc", sizeof(bytes)) == 0);
      send_frame(&endpoint, id == 3 ? FS_DIAG_RETIRED : FS_DIAG_RESULT, id,
                 NULL, 0);
    }
    CHECK(endpoint.retired);
    _exit(0);
  }
  fs_diag_endpoint endpoint;
  CHECK(fs_diag_endpoint_init(&endpoint, page, FS_DIAG_ENDPOINT_PARENT) ==
        FS_DIAG_CHANNEL_COMPLETE);
  uint8_t output[1];
  receive_frame(&endpoint, output, 0);
  for (uint64_t id = 1; id != 4; ++id) {
    send_frame(&endpoint,
               id == 1   ? FS_DIAG_INIT
               : id == 2 ? FS_DIAG_APPEND
                         : FS_DIAG_RETIRE,
               id, id == 3 ? NULL : (const uint8_t *)"abc", id == 3 ? 0 : 3);
    receive_frame(&endpoint, output, 0);
  }
  CHECK(endpoint.retired);
  int status;
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0);
  CHECK(munmap(page, FS_DIAG_PAGE_BYTES) == 0);
}

int main(void) {
  alarm(10);
  CHECK(fs_diag_endpoint_init(NULL, NULL, 0) == FS_DIAG_CHANNEL_ERROR);
  lifecycle();
  malformed();
  exhaustion();
  cross_process();
  puts("endpoint handshake, request/reply ownership, poison and fork controls "
       "passed");
  return 0;
}
