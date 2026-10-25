#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "sql_support.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <time.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 &&
                   ATOMIC_INT_LOCK_FREE == 2,
               "SQL support requires lock-free native integer atomics");

typedef struct {
  _Atomic uint64_t lease;
  struct sqlite3 *database;
  fs_sql_progress_install install;
  int64_t deadline;
  int expired;
} sql_slot;

static sql_slot slots[FS_SQL_SUPPORT_CAPACITY];
static _Atomic uint64_t next_lease = 1;
static _Atomic int initialized;
static pthread_once_t initialize_once = PTHREAD_ONCE_INIT;

static int support_ready(void) {
  return atomic_load_explicit(&initialized, memory_order_acquire) == 1;
}

static int monotonic_ns(int64_t *result) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) || now.tv_sec < 0 ||
      now.tv_sec > (INT64_MAX - now.tv_nsec) / INT64_C(1000000000))
    return 0;
  *result = (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
  return 1;
}

/* No VM entry, allocation, lock, SQLite reentry or loader operation. SQLite
 * invokes this on the same owner thread that is executing its statement. */
static int check_deadline(void *context) {
  sql_slot *slot = context;
  int64_t now;
  if (!slot->expired && (!monotonic_ns(&now) || now >= slot->deadline))
    slot->expired = 1;
  return slot->expired;
}

static int64_t begin(struct sqlite3 *database, fs_sql_progress_install install,
                     int64_t budget_ns) {
  int64_t now;
  if (!support_ready())
    return FS_SQL_NOT_READY;
  if (!database || !install || budget_ns <= 0 ||
      budget_ns > FS_SQL_SUPPORT_MAX_BUDGET_NS)
    return FS_SQL_INVALID_ARGUMENT;
  if (!monotonic_ns(&now) || now > INT64_MAX - budget_ns)
    return FS_SQL_CLOCK_FAILED;

  uint64_t lease = atomic_load(&next_lease);
  do {
    if (lease >= INT64_MAX)
      return FS_SQL_LEASE_EXHAUSTED;
  } while (!atomic_compare_exchange_weak(&next_lease, &lease, lease + 1));

  for (size_t n = 0; n < FS_SQL_SUPPORT_CAPACITY; ++n) {
    uint64_t empty = 0;
    /* Reserve without publishing a valid lease until all fields/registration
     * are initialized. UINT64_MAX is never a caller-visible token. */
    if (!atomic_compare_exchange_strong_explicit(
            &slots[n].lease, &empty, UINT64_MAX, memory_order_acq_rel,
            memory_order_relaxed))
      continue;
    slots[n].database = database;
    slots[n].install = install;
    slots[n].deadline = now + budget_ns;
    slots[n].expired = 0;
    install(database, FS_SQL_SUPPORT_INTERVAL, check_deadline, &slots[n]);
    atomic_store_explicit(&slots[n].lease, lease, memory_order_release);
    return (int64_t)lease;
  }
  return FS_SQL_POOL_FULL;
}

static int end(int64_t lease) {
  if (lease <= 0)
    return FS_SQL_INVALID_LEASE;
  for (size_t n = 0; n < FS_SQL_SUPPORT_CAPACITY; ++n) {
    if (atomic_load_explicit(&slots[n].lease, memory_order_acquire) !=
        (uint64_t)lease)
      continue;
    /* This connection is exclusively owned by the caller. The statement has
     * returned; its last callback cannot still be executing concurrently. */
    slots[n].install(slots[n].database, 0, NULL, NULL);
    int result = slots[n].expired ? FS_SQL_EXPIRED : FS_SQL_SETTLED;
    slots[n].database = NULL;
    slots[n].install = NULL;
    atomic_store_explicit(&slots[n].lease, 0, memory_order_release);
    return result;
  }
  return FS_SQL_INVALID_LEASE;
}

static const fs_sql_api api = {FS_SQL_SUPPORT_ABI,
                               sizeof(fs_sql_api),
                               FS_SQL_SUPPORT_CAPACITY,
                               FS_SQL_SUPPORT_INTERVAL,
                               support_ready,
                               begin,
                               end};

static int same_image(const void *address, const void *base) {
  Dl_info symbol = {0};
  return dladdr(address, &symbol) && symbol.dli_fbase == base;
}

static void initialize_image(void) {
  atomic_store_explicit(&initialized, -1, memory_order_release);
  Dl_info own = {0};
  if (!dladdr((const void *)&fs_sql_support_early_init, &own) || !own.dli_fname)
    return;
  void *mapping = dlopen(own.dli_fname, RTLD_NOW | RTLD_NOLOAD);
  if (!mapping)
    return;
  const void *resolved = dlsym(mapping, "fs_sql_support_early_init");
  if (!resolved || !same_image(resolved, own.dli_fbase) ||
      !same_image((const void *)api.ready, own.dli_fbase) ||
      !same_image((const void *)api.begin, own.dli_fbase) ||
      !same_image((const void *)api.end, own.dli_fbase)) {
    /* This loader-owner failure occurs before any database can be opened. */
    dlclose(mapping);
    return;
  }
  /* Exactly one process-owned reference. Never ordinarily closed by a VM. */
  atomic_store_explicit(&initialized, 1, memory_order_release);
}

const fs_sql_api *fs_sql_support_early_init(uint32_t requested_abi) {
  if (requested_abi != FS_SQL_SUPPORT_ABI)
    return NULL;
  if (pthread_once(&initialize_once, initialize_image) || !support_ready())
    return NULL;
  return &api;
}
