#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "sql_support.h"

#include <dlfcn.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expression)                                                      \
  do {                                                                         \
    if (!(expression)) {                                                       \
      fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expression);         \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static const char long_sql[] =
    "WITH RECURSIVE counter(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM counter "
    "WHERE x<1000000000) SELECT sum(x) FROM counter";
static const fs_sql_api *(*early_init)(uint32_t);
static const fs_sql_api *initializers[8];

static void *initialize_thread(void *argument) {
  size_t index = (size_t)argument;
  initializers[index] = early_init(FS_SQL_SUPPORT_ABI);
  return NULL;
}

static void *query_thread(void *argument) {
  const fs_sql_api *api = argument;
  sqlite3 *db = NULL;
  CHECK(sqlite3_open(":memory:", &db) == SQLITE_OK);
  for (size_t n = 0; n < 16; ++n) {
    int64_t lease = api->begin(db, sqlite3_progress_handler, INT64_C(3000000));
    CHECK(lease > 0);
    CHECK(sqlite3_exec(db, long_sql, NULL, NULL, NULL) == SQLITE_INTERRUPT);
    CHECK(api->end(lease) == FS_SQL_EXPIRED);
    CHECK(api->end(lease) == FS_SQL_INVALID_LEASE);
    CHECK(sqlite3_exec(db, "SELECT 42", NULL, NULL, NULL) == SQLITE_OK);
  }
  CHECK(sqlite3_close(db) == SQLITE_OK);
  return NULL;
}

int main(int argc, char **argv) {
  CHECK(argc == 3);
  /* A no-pin control must really unload. Never call its pointer afterward. */
  void *control = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
  CHECK(control != NULL);
  CHECK(dlsym(control, "fs_sql_unpinned_fixture") != NULL);
  CHECK(dlclose(control) == 0);
  CHECK(dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD) == NULL);

  void *image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  CHECK(image != NULL);
  early_init = (const fs_sql_api *(*)(uint32_t))dlsym(
      image, "fs_sql_support_early_init");
  CHECK(early_init != NULL);
  CHECK(early_init(FS_SQL_SUPPORT_ABI + 1) == NULL);
  pthread_t threads[8];
  for (size_t n = 0; n < 8; ++n)
    CHECK(pthread_create(&threads[n], NULL, initialize_thread, (void *)n) == 0);
  for (size_t n = 0; n < 8; ++n)
    CHECK(pthread_join(threads[n], NULL) == 0);
  const fs_sql_api *api = initializers[0];
  CHECK(api != NULL && api->abi_version == FS_SQL_SUPPORT_ABI &&
        api->struct_size == sizeof(fs_sql_api) &&
        api->capacity == FS_SQL_SUPPORT_CAPACITY &&
        api->instruction_interval == FS_SQL_SUPPORT_INTERVAL);
  for (size_t n = 0; n < 8; ++n)
    CHECK(initializers[n] == api);
  CHECK(api->ready() == 1);

  /* All code/pin probes, including ordinary dlclose, precede DB creation. */
  CHECK(dlclose(image) == 0);
  void *retained = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
  CHECK(retained != NULL);
  CHECK(dlclose(retained) == 0);
  CHECK(api->ready() == 1);

  sqlite3 *db[FS_SQL_SUPPORT_CAPACITY + 1] = {0};
  int64_t lease[FS_SQL_SUPPORT_CAPACITY];
  for (size_t n = 0; n <= FS_SQL_SUPPORT_CAPACITY; ++n)
    CHECK(sqlite3_open(":memory:", &db[n]) == SQLITE_OK);
  CHECK(api->begin(NULL, sqlite3_progress_handler, 1) ==
        FS_SQL_INVALID_ARGUMENT);
  CHECK(api->begin(db[0], NULL, 1) == FS_SQL_INVALID_ARGUMENT);
  CHECK(api->begin(db[0], sqlite3_progress_handler, 0) ==
        FS_SQL_INVALID_ARGUMENT);
  CHECK(api->begin(db[0], sqlite3_progress_handler,
                   FS_SQL_SUPPORT_MAX_BUDGET_NS + 1) ==
        FS_SQL_INVALID_ARGUMENT);
  for (size_t n = 0; n < FS_SQL_SUPPORT_CAPACITY; ++n) {
    lease[n] = api->begin(db[n], sqlite3_progress_handler,
                          FS_SQL_SUPPORT_MAX_BUDGET_NS);
    CHECK(lease[n] > 0);
  }
  CHECK(api->begin(db[FS_SQL_SUPPORT_CAPACITY], sqlite3_progress_handler,
                   INT64_C(10000000)) == FS_SQL_POOL_FULL);
  CHECK(api->end(lease[0]) == FS_SQL_SETTLED);
  int64_t replacement =
      api->begin(db[0], sqlite3_progress_handler, INT64_C(10000000));
  CHECK(replacement > 0 && replacement != lease[0]);
  CHECK(api->end(lease[0]) == FS_SQL_INVALID_LEASE);
  CHECK(sqlite3_exec(db[0], long_sql, NULL, NULL, NULL) == SQLITE_INTERRUPT);
  CHECK(api->end(replacement) == FS_SQL_EXPIRED);
  CHECK(api->end(replacement) == FS_SQL_INVALID_LEASE);
  CHECK(sqlite3_exec(db[0], "SELECT 42", NULL, NULL, NULL) == SQLITE_OK);
  for (size_t n = 1; n < FS_SQL_SUPPORT_CAPACITY; ++n)
    CHECK(api->end(lease[n]) == FS_SQL_SETTLED);
  CHECK(sqlite3_exec(db[FS_SQL_SUPPORT_CAPACITY], "SELECT 73", NULL, NULL,
                     NULL) == SQLITE_OK);
  for (size_t n = 0; n <= FS_SQL_SUPPORT_CAPACITY; ++n)
    CHECK(sqlite3_close(db[n]) == SQLITE_OK);

  /* Distinct connections/owners stress shared slot reuse without sharing a DB.
   */
  for (size_t n = 0; n < 4; ++n)
    CHECK(pthread_create(&threads[n], NULL, query_thread, (void *)api) == 0);
  for (size_t n = 0; n < 4; ++n)
    CHECK(pthread_join(threads[n], NULL) == 0);
  puts(
      "PASS: concurrent early init, image pin/no-pin control, 64-slot "
      "pressure, "
      "stale-lease ABA, real expiry, independent next jobs, concurrent owners");
  return 0;
}
