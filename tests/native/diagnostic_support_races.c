#define _GNU_SOURCE
#include "diagnostic_protocol.h"
#include "diagnostic_support.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef _Atomic(fs_diag_page *) atomic_page;
static void fixture_store_word(fs_diag_atomic64 *, uint64_t);
static void fixture_store_int(atomic_int *, int);
static void fixture_store_page(atomic_page *, fs_diag_page *);
static bool fixture_compare_word(fs_diag_atomic64 *, uint64_t *, uint64_t);
static bool fixture_compare_int(atomic_int *, int *, int);

// Compile the unchanged production owner in this test TU. Interpose ONLY its
// C11 atomic publication primitives to hold the exact old load/store race. No
// sleep, hook, descriptor argument or test selector enters product code.
#undef atomic_store
#define atomic_store(object, value)                                            \
  _Generic((object),                                                           \
      fs_diag_atomic64 *: fixture_store_word,                                  \
      atomic_int *: fixture_store_int,                                         \
      atomic_page *: fixture_store_page)((object), (value))
#undef atomic_compare_exchange_strong
#define atomic_compare_exchange_strong(object, expected, value)                \
  _Generic((object),                                                           \
      fs_diag_atomic64 *: fixture_compare_word,                                \
      atomic_int *: fixture_compare_int)((object), (expected), (value))
#include "../../native/diagnostic_support.c"

static atomic_int publication_waiting;
static atomic_int publication_release;

static void pause_publication(fs_diag_atomic64 *word, uint64_t value) {
  fs_diag_page *page = atomic_load(&context.page);
  if (page == NULL || word != &page->header.control_command ||
      value != context.probe)
    return;
  atomic_store_explicit(&publication_waiting, 1, memory_order_seq_cst);
  for (int i = 0; i != 2000; ++i) {
    if (atomic_load(&publication_release))
      return;
    const struct timespec delay = {0, 1000000};
    nanosleep(&delay, NULL);
  }
  assert(!"publication fixture release deadline");
}

static void fixture_store_word(fs_diag_atomic64 *word, uint64_t value) {
  pause_publication(word, value);
  atomic_store_explicit(word, value, memory_order_seq_cst);
}
static void fixture_store_int(atomic_int *word, int value) {
  atomic_store_explicit(word, value, memory_order_seq_cst);
}
static void fixture_store_page(atomic_page *word, fs_diag_page *value) {
  atomic_store_explicit(word, value, memory_order_seq_cst);
}
static bool fixture_compare_word(fs_diag_atomic64 *word, uint64_t *expected,
                                 uint64_t desired) {
  pause_publication(word, desired);
  return atomic_compare_exchange_strong_explicit(
      word, expected, desired, memory_order_seq_cst, memory_order_seq_cst);
}
static bool fixture_compare_int(atomic_int *word, int *expected, int desired) {
  return atomic_compare_exchange_strong_explicit(
      word, expected, desired, memory_order_seq_cst, memory_order_seq_cst);
}

static void *spawn_held(void *unused) {
  (void)unused;
  assert(fs_diag_parent_spawn(1) == FS_DIAG_SUPPORT_SPAWNED);
  return NULL;
}

int main(int argc, char **argv) {
  assert(argc == 3);
  alarm(10);
#ifdef FS_DIAG_FIXTURE_BASE
  assert(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0 || errno == EEXIST);
#endif
  char parent[24], arguments[2048];
  snprintf(parent, sizeof(parent), "%ld", (long)getpid());
  const char *items[] = {argv[1],    native_identity, parent, argv[2],
                         "--worker", parent,          "hold"};
  uint32_t length = 0;
  for (unsigned i = 0; i != 7; ++i) {
    size_t size = strlen(items[i]) + 1;
    assert(length + size <= sizeof(arguments));
    memcpy(arguments + length, items[i], size);
    length += (uint32_t)size;
  }
  assert(fs_diag_parent_reserve(native_identity, native_identity,
                                native_identity, (uint8_t *)arguments, length,
                                7) == 1);
  assert(fs_diag_parent_prepare(1) == FS_DIAG_SUPPORT_PREPARED);
  pthread_t thread;
  assert(pthread_create(&thread, NULL, spawn_held, NULL) == 0);
  for (int i = 0; !atomic_load(&publication_waiting) && i != 2000; ++i) {
    const struct timespec delay = {0, 1000000};
    nanosleep(&delay, NULL);
  }
  assert(atomic_load(&publication_waiting));
  assert(fs_diag_parent_force(1) == FS_DIAG_SUPPORT_CANCELLED);
  atomic_store_explicit(&publication_release, 1, memory_order_seq_cst);
  assert(pthread_join(thread, NULL) == 0);
  uint64_t final_command =
      atomic_load(&atomic_load(&context.page)->header.control_command);
  // Also retire/reap the actual child on the old-code negative path BEFORE
  // failing its oracle; an assertion failure must not abandon a live process.
  assert(fs_diag_parent_force(1) == FS_DIAG_SUPPORT_CANCELLED);
  int status = 0;
  for (int i = 0; i != 200; ++i) {
    status = fs_diag_parent_poll(1);
    assert(status >= 0);
    if (status & FS_DIAG_SUPPORT_NOT_LIVE)
      break;
    const struct timespec delay = {0, 10000000};
    nanosleep(&delay, NULL);
  }
  assert(status & FS_DIAG_SUPPORT_NOT_LIVE);
  assert(final_command == context.force);
  assert(fs_diag_support_send(1, FS_DIAG_INIT, 1, 0, NULL, 0) ==
         FS_DIAG_CHANNEL_ERROR);
  puts("diagnostic support: held spawn publication preserves FORCE");
  return 0;
}
