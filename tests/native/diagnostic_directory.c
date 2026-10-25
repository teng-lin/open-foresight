#define _GNU_SOURCE
#include "diagnostic_support.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/mount.h>
#endif

// Metadata controls replace only fstat/fstatfs observations of the real
// descriptor. fdopendir is never replaced; a refused gate must not reach it.
static int fail_fstat;
static long forced_block = -1;
static int fstat_calls;
int fs_diag_test_fstat(int descriptor, struct stat *information) {
  ++fstat_calls;
  if (fail_fstat)
    return -1;
  int result = fstat(descriptor, information);
  if (result == 0 && forced_block >= 0)
    information->st_blksize = (blksize_t)forced_block;
  return result;
}
#ifdef __APPLE__
static int force_union, fail_fstatfs;
int fs_diag_test_fstatfs(int descriptor, struct statfs *volume) {
  if (fail_fstatfs)
    return -1;
  int result = fstatfs(descriptor, volume);
  if (result == 0 && force_union)
    volume->f_flags |= MNT_UNION;
  return result;
}
#endif

static int failures;
#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition);          \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

// The storage order: policy on the anchored descriptor, then the utility's
// fdopendir(openat(anchor, ".")). Returns entries or -1 when refused.
static int fdopendir_calls;
static int gated_entries(int anchor) {
  if (fs_diag_directory_bound(anchor) != FS_DIAG_DIRECTORY_OK)
    return -1;
  int duplicate = openat(anchor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (duplicate < 0)
    return -2;
  ++fdopendir_calls;
  DIR *directory = fdopendir(duplicate);
  if (directory == NULL) {
    close(duplicate);
    return -2;
  }
  int count = 0;
  for (struct dirent *entry; (entry = readdir(directory)) != NULL;)
    if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, ".."))
      ++count;
  closedir(directory);
  return count;
}

int main(void) {
  const char *root = getenv("TMPDIR");
  char base[512];
  snprintf(base, sizeof(base), "%s/fsdirXXXXXX", root ? root : "/tmp");
  if (mkdtemp(base) == NULL) {
    perror("mkdtemp");
    return 2;
  }
  int anchor = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  char name[sizeof(base) + 8];
  snprintf(name, sizeof(name), "%s/entry", base);
  int file = open(name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  CHECK(anchor >= 0 && file >= 0);

  // Ordinary real directory on this host's filesystem is accepted.
  struct stat real;
  CHECK(fstat(anchor, &real) == 0);
  printf("real st_blksize=%ld\n", (long)real.st_blksize);
  CHECK(fs_diag_directory_bound(anchor) == FS_DIAG_DIRECTORY_OK);
  CHECK(gated_entries(anchor) == 1 && fdopendir_calls == 1);

  // Non-directory, invalid and closed descriptors never become admissible.
  CHECK(fs_diag_directory_bound(file) == FS_DIAG_DIRECTORY_UNSUPPORTED);
  CHECK(fs_diag_directory_bound(-1) == FS_DIAG_SUPPORT_ERROR);
  int closed = dup(anchor);
  close(closed);
  CHECK(fs_diag_directory_bound(closed) == FS_DIAG_SUPPORT_ERROR);
  fail_fstat = 1;
  fstat_calls = 0;
  CHECK(fs_diag_directory_bound(anchor) == FS_DIAG_SUPPORT_ERROR);
  CHECK(fstat_calls == 1);
  fail_fstat = 0;

#ifdef __linux__
  // glibc sizes DIR from st_blksize up to 1MiB. Exact bound edge controls.
  const struct {
    long block;
    int expected;
  } blocks[] = {
      {1, FS_DIAG_DIRECTORY_OK},
      {4096, FS_DIAG_DIRECTORY_OK},
      {32768, FS_DIAG_DIRECTORY_OK},
      {FS_DIAG_DIRECTORY_BLOCK_BYTES, FS_DIAG_DIRECTORY_OK},
      {FS_DIAG_DIRECTORY_BLOCK_BYTES + 1, FS_DIAG_DIRECTORY_UNSUPPORTED},
      {1048576, FS_DIAG_DIRECTORY_UNSUPPORTED},
      {0, FS_DIAG_DIRECTORY_UNSUPPORTED}};
  for (unsigned i = 0; i != sizeof(blocks) / sizeof(blocks[0]); ++i) {
    forced_block = blocks[i].block;
    CHECK(fs_diag_directory_bound(anchor) == blocks[i].expected);
  }
  // A refused large hint never reaches fdopendir/readdir.
  forced_block = 1048576;
  fdopendir_calls = 0;
  CHECK(gated_entries(anchor) == -1 && fdopendir_calls == 0);
  forced_block = -1;
#else
  // Darwin MNT_UNION would make fdopendir read the complete union stack.
  force_union = 1;
  fdopendir_calls = 0;
  CHECK(fs_diag_directory_bound(anchor) == FS_DIAG_DIRECTORY_UNSUPPORTED);
  CHECK(gated_entries(anchor) == -1 && fdopendir_calls == 0);
  force_union = 0;
  fail_fstatfs = 1;
  CHECK(fs_diag_directory_bound(anchor) == FS_DIAG_SUPPORT_ERROR);
  fail_fstatfs = 0;
  // Ordinary APFS-sized st_blksize hints are irrelevant to Darwin Libc sizing.
  forced_block = 1048576;
  CHECK(fs_diag_directory_bound(anchor) == FS_DIAG_DIRECTORY_OK);
  forced_block = -1;
#endif
  CHECK(gated_entries(anchor) == 1);

  close(file);
  close(anchor);
  unlink(name);
  rmdir(base);
  if (failures)
    fprintf(stderr, "%d diagnostic directory checks failed\n", failures);
  return failures != 0;
}
