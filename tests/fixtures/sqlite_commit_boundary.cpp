/* Private crash characterization: delegate all SQLite work to its normal VFS.
 * Interrupt only the real superjournal deletion at its documented commit point.
 */
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static sqlite3_vfs *original;
static const char *boundary;
static int deleting(sqlite3_vfs *vfs, const char *path, int sync_dir) {
  (void)vfs;
  if (strstr(path, "-mj") && strcmp(boundary, "before") == 0)
    _exit(41);
  int result = original->xDelete(original, path, sync_dir);
  if (strstr(path, "-mj") && strcmp(boundary, "after") == 0)
    _exit(42);
  return result;
}
static void sql(sqlite3 *db, const char *statement) {
  char *error = NULL;
  if (sqlite3_exec(db, statement, NULL, NULL, &error) != SQLITE_OK) {
    fprintf(stderr, "%s: %s\n", statement, error);
    sqlite3_free(error);
    exit(1);
  }
}
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--sqlite-version") == 0) {
    puts(sqlite3_libversion());
    return 0;
  }
  if (argc != 4)
    return 2;
  if (chdir(argv[1]))
    return 3;
  boundary = argv[2];
  sqlite3 *db = NULL;
  if (sqlite3_open("agent_metadata.db", &db) != SQLITE_OK)
    return 4;
  sql(db,
      "ATTACH 'linux_state.db' AS linux; ATTACH 'rag_vector.db' AS vectors;");
  sql(db, "PRAGMA main.journal_mode=DELETE; PRAGMA linux.journal_mode=DELETE; "
          "PRAGMA vectors.journal_mode=DELETE; PRAGMA synchronous=FULL;");
  char *initial =
      sqlite3_mprintf("PRAGMA main.user_version=%q; PRAGMA "
                      "linux.user_version=%q; PRAGMA vectors.user_version=%q;",
                      argv[3], argv[3], argv[3]);
  sql(db, initial);
  sqlite3_free(initial);
  /* All file handles retain normal file methods. Copying the default VFS only
   * substitutes its deletion callback, never any read/write/recovery logic. */
  original = sqlite3_vfs_find(NULL);
  sqlite3_vfs probe = *original;
  probe.zName = "foresight-commit-boundary";
  probe.pNext = NULL;
  probe.xDelete = deleting;
  sqlite3_vfs_register(&probe, 1);
  sqlite3_close(db);
  if (sqlite3_open("agent_metadata.db", &db) != SQLITE_OK)
    return 5;
  sql(db,
      "ATTACH 'linux_state.db' AS linux; ATTACH 'rag_vector.db' AS vectors;");
  sql(db, "BEGIN IMMEDIATE; PRAGMA main.user_version=0; PRAGMA "
          "linux.user_version=0; PRAGMA vectors.user_version=0; UPDATE "
          "documents SET content='committed boundary body'; UPDATE "
          "linux.source_revisions SET revision=8; UPDATE vectors.chunks SET "
          "embedding='[2.5]',revision=8; COMMIT;");
  sqlite3_close(db);
  return 6; /* A real attached commit must call the superjournal delete hook. */
}
