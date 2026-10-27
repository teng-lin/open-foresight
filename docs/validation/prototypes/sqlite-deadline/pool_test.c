#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <dlfcn.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

typedef void (*install_progress)(sqlite3 *, int, int (*)(void *), void *);
static const char *long_sql =
    "WITH RECURSIVE counter(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM counter "
    "WHERE x<1000000000) SELECT sum(x) FROM counter";
int main(int argc, char **argv) {
  assert(argc == 2);
  void *image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  assert(image);
  int (*initialize)(void) =
      (int (*)(void))dlsym(image, "of_sql_deadline_initialize");
  uint64_t (*begin)(sqlite3 *, install_progress, int64_t) =
      (uint64_t (*)(sqlite3 *, install_progress, int64_t))dlsym(
          image, "of_sql_deadline_begin");
  int (*end)(uint64_t) = (int (*)(uint64_t))dlsym(image, "of_sql_deadline_end");
  assert(initialize && begin && end && initialize() == 1 && initialize() == 1);
  /* Drop the caller mapping before any DB exists: only C's process-owned pin
   * now keeps all function/context addresses alive. */
  assert(dlclose(image) == 0);
  sqlite3 *db[65] = {0};
  uint64_t lease[64];
  for (size_t n = 0; n < 65; ++n)
    assert(sqlite3_open(":memory:", &db[n]) == SQLITE_OK);
  assert(begin(NULL, sqlite3_progress_handler, 1) == 0);
  assert(begin(db[0], NULL, 1) == 0);
  assert(begin(db[0], sqlite3_progress_handler, 0) == 0);
  assert(begin(db[0], sqlite3_progress_handler, INT64_C(30000000001)) == 0);
  for (size_t n = 0; n < 64; ++n) {
    lease[n] = begin(db[n], sqlite3_progress_handler, INT64_C(30000000000));
    assert(lease[n]);
  }
  assert(begin(db[64], sqlite3_progress_handler, 10000000) == 0);
  assert(end(lease[0]) == 0);
  uint64_t replacement = begin(db[0], sqlite3_progress_handler, 10000000);
  assert(replacement && replacement != lease[0]);
  assert(end(lease[0]) ==
         -1); /* Must not unregister replacement at same slot. */
  struct timespec start, finish;
  assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
  assert(sqlite3_exec(db[0], long_sql, NULL, NULL, NULL) == SQLITE_INTERRUPT);
  assert(clock_gettime(CLOCK_MONOTONIC, &finish) == 0);
  assert((finish.tv_sec - start.tv_sec) * INT64_C(1000000000) + finish.tv_nsec -
             start.tv_nsec <
         INT64_C(2000000000));
  assert(end(replacement) == 1 && end(replacement) == -1);
  assert(sqlite3_exec(db[0], "SELECT 42", NULL, NULL, NULL) == SQLITE_OK);
  for (size_t n = 1; n < 64; ++n)
    assert(end(lease[n]) == 0);
  assert(sqlite3_exec(
             db[64],
             "WITH RECURSIVE counter(x) AS (VALUES(0) UNION ALL SELECT x+1 "
             "FROM counter WHERE x<100000) SELECT sum(x) FROM counter",
             NULL, NULL, NULL) == SQLITE_OK);
  for (size_t n = 0; n < 65; ++n)
    assert(sqlite3_close(db[n]) == SQLITE_OK);
  puts("PASS:64-slot pressure,65th refusal,stale lease ABA refusal,real "
       "expiry,next-job/other-connection,code pin after caller dlclose");
  return 0;
}
