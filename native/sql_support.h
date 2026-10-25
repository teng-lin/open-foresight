#ifndef FORESIGHT_SQL_SUPPORT_H
#define FORESIGHT_SQL_SUPPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FS_SQL_SUPPORT_ABI 1
#define FS_SQL_SUPPORT_CAPACITY 64
#define FS_SQL_SUPPORT_INTERVAL 1000
#define FS_SQL_SUPPORT_MAX_BUDGET_NS INT64_C(30000000000)

struct sqlite3;
typedef void (*fs_sql_progress_install)(struct sqlite3 *, int, int (*)(void *),
                                        void *);

enum fs_sql_result {
  FS_SQL_SETTLED = 0,
  FS_SQL_EXPIRED = 1,
  FS_SQL_NOT_READY = -1,
  FS_SQL_INVALID_ARGUMENT = -2,
  FS_SQL_CLOCK_FAILED = -3,
  FS_SQL_POOL_FULL = -4,
  FS_SQL_LEASE_EXHAUSTED = -5,
  FS_SQL_INVALID_LEASE = -6
};

/* Immutable code table. An owning startup gate resolves it from the trusted
 * original support image before any application database opens, verifies the
 * ABI/size, and passes only these original code addresses to read owners.
 * There is no database or context pointer in that cross-isolate bootstrap. */
typedef struct fs_sql_api {
  uint32_t abi_version;
  uint32_t struct_size;
  uint32_t capacity;
  uint32_t instruction_interval;
  int (*ready)(void);
  /* Positive, nonrepeating lease on success; negative fs_sql_result on failure.
   * The database and its original install function belong to this caller. */
  int64_t (*begin)(struct sqlite3 *, fs_sql_progress_install,
                   int64_t budget_ns);
  /* Call only after synchronous SQL has actually returned. Unregisters before
   * releasing its slot. A lost VM retains its slot until process death. */
  int (*end)(int64_t lease);
} fs_sql_api;

/* Loader-owner operation ONLY, before database locks/worker creation. The
 * initializer retains the already mapped image and checks every code entry.
 * Concurrent early callers join the same once-only initialization. Failure is
 * permanent and returns NULL; a worker never receives this operation. */
__attribute__((visibility("default"))) const fs_sql_api *
fs_sql_support_early_init(uint32_t requested_abi);

#ifdef __cplusplus
}
#endif
#endif
