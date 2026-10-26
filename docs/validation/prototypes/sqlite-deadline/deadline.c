#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <limits.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#ifdef OF_SQL_DEADLINE_PROOF
#include <stdio.h>
#include <unistd.h>
static _Atomic unsigned long proof_begun, proof_ended, proof_expired;
__attribute__((destructor)) static void proof_report(void) {
  char message[160];
  int length =
      snprintf(message, sizeof(message),
               "SQL_DEADLINE_PROOF begun=%lu ended=%lu expired=%lu live=%lu\n",
               atomic_load(&proof_begun), atomic_load(&proof_ended),
               atomic_load(&proof_expired),
               atomic_load(&proof_begun) - atomic_load(&proof_ended));
  if (length > 0 && (size_t)length < sizeof(message))
    (void)write(STDERR_FILENO, message, (size_t)length);
}
#endif

typedef struct sqlite3 sqlite3;
typedef void (*install_progress)(sqlite3 *, int, int (*)(void *), void *);
#define SLOT_COUNT 64
#define MAX_BUDGET_NS INT64_C(30000000000)

typedef struct {
  _Atomic uint64_t lease;
  sqlite3 *database;
  install_progress install;
  int64_t deadline;
  int expired;
} deadline_slot;
static deadline_slot slots[SLOT_COUNT];
static _Atomic uint64_t next_lease = 1;
static _Atomic int initialized;

int of_sql_deadline_initialize(void);

/* Pin only this already mapped tiny image, before any database is opened. */
int of_sql_deadline_initialize(void) {
  int expected = 0;
  if (!atomic_compare_exchange_strong(&initialized, &expected, -1))
    return expected == 1;
  Dl_info own = {0}, symbol = {0};
  if (!dladdr((void *)&of_sql_deadline_initialize, &own) || !own.dli_fname)
    return 0;
  void *mapping = dlopen(own.dli_fname, RTLD_NOW | RTLD_NOLOAD);
  if (!mapping)
    return 0;
  void *resolved = dlsym(mapping, "of_sql_deadline_initialize");
  if (!resolved || !dladdr(resolved, &symbol) ||
      symbol.dli_fbase != own.dli_fbase) {
    dlclose(mapping);
    return 0;
  }
  /* One process-owned reference intentionally outlives all Dart loaders. */
  atomic_store_explicit(&initialized, 1, memory_order_release);
  return 1;
}

static int monotonic_ns(int64_t *result) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) || value.tv_sec < 0 ||
      value.tv_sec > (INT64_MAX - value.tv_nsec) / INT64_C(1000000000))
    return 0;
  *result = (int64_t)value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
  return 1;
}

/* No allocation, VM entry, Dart callback, SQLite reentry, or library lookup. */
static int check_deadline(void *context) {
  deadline_slot *slot = context;
  int64_t now;
  if (!slot->expired && (!monotonic_ns(&now) || now >= slot->deadline)) {
    slot->expired = 1;
#ifdef OF_SQL_DEADLINE_PROOF
    atomic_fetch_add(&proof_expired, 1);
#endif
  }
  return slot->expired;
}

uint64_t of_sql_deadline_begin(sqlite3 *database, install_progress install,
                               int64_t budget_ns) {
  int64_t now;
  if (atomic_load_explicit(&initialized, memory_order_acquire) != 1 ||
      !database || !install || budget_ns <= 0 || budget_ns > MAX_BUDGET_NS ||
      !monotonic_ns(&now) || now > INT64_MAX - budget_ns)
    return 0;
  uint64_t lease = atomic_load(&next_lease);
  do {
    if (!lease || lease == UINT64_MAX)
      return 0;
  } while (!atomic_compare_exchange_weak(&next_lease, &lease, lease + 1));
  for (size_t n = 0; n < SLOT_COUNT; ++n) {
    uint64_t empty = 0;
    if (!atomic_compare_exchange_strong_explicit(&slots[n].lease, &empty, lease,
                                                 memory_order_acq_rel,
                                                 memory_order_relaxed))
      continue;
    slots[n].database = database;
    slots[n].install = install;
    slots[n].deadline = now + budget_ns;
    slots[n].expired = 0;
    install(database, 1000, check_deadline, &slots[n]);
#ifdef OF_SQL_DEADLINE_PROOF
    atomic_fetch_add(&proof_begun, 1);
#endif
    return lease;
  }
  return 0;
}

/* Caller owns this connection, and calls only after its statement settled.
 * Unregister before releasing the static slot. Tokens never wrap or repeat;
 * an old token cannot clear a replacement job, even when an address is reused.
 * A lost VM may retain a lease until process death; the pool remains bounded.
 */
int of_sql_deadline_end(uint64_t lease) {
  if (!lease)
    return -1;
  for (size_t n = 0; n < SLOT_COUNT; ++n) {
    if (atomic_load_explicit(&slots[n].lease, memory_order_acquire) != lease)
      continue;
    slots[n].install(slots[n].database, 0, NULL, NULL);
#ifdef OF_SQL_DEADLINE_PROOF
    atomic_fetch_add(&proof_ended, 1);
#endif
    int expired = slots[n].expired;
    slots[n].database = NULL;
    slots[n].install = NULL;
    atomic_store_explicit(&slots[n].lease, 0, memory_order_release);
    return expired;
  }
  return -1;
}
