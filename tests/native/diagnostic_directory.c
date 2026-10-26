#define _GNU_SOURCE
#include "diagnostic_support.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <stddef.h>
#include <sys/mount.h>
// diagnostic_support.c parses raw records by these explicit offsets.
_Static_assert(offsetof(struct dirent, d_reclen) == 16 &&
                   offsetof(struct dirent, d_namlen) == 18 &&
                   offsetof(struct dirent, d_type) == 20 &&
                   offsetof(struct dirent, d_name) == 21 && DT_WHT == 14,
               "Darwin 64-bit-inode dirent layout");
#else
#include <sys/vfs.h>
#endif

// The enumerator must never reach a libc directory stream. These definitions
// in the executable take every such call made by the linked support object.
static int stream_calls;
DIR *opendir(const char *path) {
  (void)path;
  ++stream_calls;
  errno = ENOSYS;
  return NULL;
}
DIR *fdopendir(int descriptor) {
  (void)descriptor;
  ++stream_calls;
  errno = ENOSYS;
  return NULL;
}
struct dirent *readdir(DIR *directory) {
  (void)directory;
  ++stream_calls;
  return NULL;
}
int closedir(DIR *directory) {
  (void)directory;
  ++stream_calls;
  return -1;
}

// Every raw read is observed: descriptor, requested size and count. Injection
// replaces only what one read returns; the real system call is otherwise used.
enum { INJECT_NONE, INJECT_ONCE, INJECT_ALWAYS, INJECT_SIZE };
static int read_calls, read_descriptor = -1, wrong_size, inject;
static unsigned char injected[FS_DIAG_DIRECTORY_RAW_BYTES];
static long injected_size;
long fs_diag_test_directory_read(int descriptor, void *buffer, size_t size,
                                 long (*real)(int, void *, size_t)) {
  ++read_calls;
  read_descriptor = descriptor;
  if (size != FS_DIAG_DIRECTORY_RAW_BYTES)
    ++wrong_size;
  if (inject == INJECT_SIZE) {
    memcpy(buffer, injected, sizeof(injected));
    return injected_size;
  }
  if (inject == INJECT_ALWAYS || (inject == INJECT_ONCE && read_calls == 1)) {
    memcpy(buffer, injected, (size_t)injected_size);
    return injected_size;
  }
  if (inject == INJECT_ONCE)
    return 0;
  return real(descriptor, buffer, size);
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

// Output plus a guard that the enumerator must never write.
enum { GUARD = 64 };
static uint8_t output[FS_DIAG_DIRECTORY_OUTPUT_BYTES + GUARD];
static int names(int descriptor) {
  memset(output, 0xa5, sizeof(output));
  read_calls = 0;
  read_descriptor = -1;
  int result = fs_diag_directory_names(descriptor, output,
                                       FS_DIAG_DIRECTORY_OUTPUT_BYTES);
  for (unsigned i = 0; i != GUARD; ++i)
    CHECK(output[FS_DIAG_DIRECTORY_OUTPUT_BYTES + i] == 0xa5);
  CHECK(read_calls <= FS_DIAG_DIRECTORY_NAMES + 3);
  return result;
}

// Whether packed output of the given length holds exactly the expected names.
static int holds(int length, const char *const *expected, unsigned count) {
  unsigned seen = 0;
  for (int offset = 0; offset < length;) {
    unsigned size = output[offset++];
    if (size == 0 || size > (unsigned)(length - offset))
      return 0;
    int known = 0;
    for (unsigned i = 0; i != count; ++i)
      known |= strlen(expected[i]) == size &&
               memcmp(expected[i], output + offset, size) == 0;
    if (!known)
      return 0;
    ++seen;
    offset += (int)size;
  }
  return seen == count;
}

static void touch(int directory, const char *name) {
  int file =
      openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  CHECK(file >= 0);
  if (file >= 0)
    close(file);
}

static void long_name(char *name, unsigned index) {
  memset(name, 'n', FS_DIAG_DIRECTORY_NAME_BYTES);
  snprintf(name, 5, "%04u", index);
  name[4] = 'n';
  name[FS_DIAG_DIRECTORY_NAME_BYTES] = '\0';
}

static void report_filesystem(const char *label, int descriptor) {
  struct statfs volume;
  if (fstatfs(descriptor, &volume) != 0) {
    printf("%s: fstatfs failed\n", label);
    return;
  }
#ifdef __APPLE__
  printf("%s: filesystem %s\n", label, volume.f_fstypename);
#else
  printf("%s: filesystem magic 0x%lx\n", label, (unsigned long)volume.f_type);
#endif
}

// Real-filesystem positives under one root: the actual descriptor, repeated
// fresh and reused descriptors, and the exact 256 x 255-byte output limit.
static void real_directory(const char *root) {
  char base[512];
  snprintf(base, sizeof(base), "%s/fsdirXXXXXX", root);
  if (mkdtemp(base) == NULL) {
    perror("mkdtemp");
    ++failures;
    return;
  }
  int anchor = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  CHECK(anchor >= 0);
  report_filesystem(root, anchor);
  CHECK(names(anchor) == 0);
  CHECK(read_descriptor == anchor && wrong_size == 0);

  CHECK(mkdirat(anchor, "x", 0700) == 0 && mkdirat(anchor, "y", 0700) == 0);
  int x = openat(anchor, "x", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  int y = openat(anchor, "y", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  touch(x, "only-x");
  touch(y, "first-y");
  touch(y, "second-y");
  const char *const top[] = {"x", "y"};
  const char *const in_x[] = {"only-x"};
  const char *const in_y[] = {"first-y", "second-y"};
  // The named descriptor is the one read, not a path or another directory.
  int length = names(x);
  CHECK(read_descriptor == x && holds(length, in_x, 1));
  length = names(y);
  CHECK(read_descriptor == y && holds(length, in_y, 2));
  // Reuse rewinds; every fresh duplicate is read from its own start.
  for (unsigned i = 0; i != 64; ++i) {
    CHECK(holds(names(y), in_y, 2));
    int duplicate = openat(anchor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    length = names(duplicate);
    CHECK(read_descriptor == duplicate && holds(length, top, 2));
    close(duplicate);
  }

  int full = -1;
  CHECK(mkdirat(anchor, "full", 0700) == 0);
  full = openat(anchor, "full", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  char name[FS_DIAG_DIRECTORY_NAME_BYTES + 1];
  for (unsigned i = 0; i != FS_DIAG_DIRECTORY_NAMES; ++i) {
    long_name(name, i);
    touch(full, name);
  }
  length = names(full);
  CHECK(length == FS_DIAG_DIRECTORY_OUTPUT_BYTES);
  unsigned complete = 0;
  for (int offset = 0; length > 0 && offset < length;) {
    unsigned size = output[offset++];
    unsigned index = 0;
    CHECK(size == FS_DIAG_DIRECTORY_NAME_BYTES &&
          sscanf((const char *)output + offset, "%4u", &index) == 1);
    long_name(name, index);
    complete += index < FS_DIAG_DIRECTORY_NAMES &&
                memcmp(output + offset, name, size) == 0;
    offset += (int)size;
  }
  CHECK(complete == FS_DIAG_DIRECTORY_NAMES);
  long_name(name, FS_DIAG_DIRECTORY_NAMES);
  touch(full, name);
  CHECK(names(full) == FS_DIAG_DIRECTORY_UNSUPPORTED);
  CHECK(wrong_size == 0);

  for (unsigned i = 0; i <= FS_DIAG_DIRECTORY_NAMES; ++i) {
    long_name(name, i);
    unlinkat(full, name, 0);
  }
  unlinkat(x, "only-x", 0);
  unlinkat(y, "first-y", 0);
  unlinkat(y, "second-y", 0);
  close(full);
  close(x);
  close(y);
  unlinkat(anchor, "full", AT_REMOVEDIR);
  unlinkat(anchor, "x", AT_REMOVEDIR);
  unlinkat(anchor, "y", AT_REMOVEDIR);
  close(anchor);
  rmdir(base);
}

// Appends one raw record in this platform's layout. A zero record length is
// computed; declared < 0 means the actual Darwin name length.
static long put(long at, uint64_t inode, const char *name, int declared,
                unsigned record, unsigned char type) {
  size_t bytes = strlen(name);
#ifdef __APPLE__
  const size_t header = 21;
#else
  const size_t header = 19;
#endif
  if (record == 0)
    record = (unsigned)((header + bytes + 1 + 7) & ~(size_t)7);
  memset(injected + at, 0, record);
  memcpy(injected + at, &inode, sizeof(inode));
  uint16_t length = (uint16_t)record;
  memcpy(injected + at + 16, &length, sizeof(length));
#ifdef __APPLE__
  uint16_t namlen = (uint16_t)(declared < 0 ? (int)bytes : declared);
  memcpy(injected + at + 18, &namlen, sizeof(namlen));
  injected[at + 20] = type;
#else
  (void)declared;
  injected[at + 18] = type;
#endif
  size_t copy = bytes < record - header ? bytes : record - header;
  memcpy(injected + at + header, name, copy);
  return at + (long)record;
}

static int injected_names(int descriptor, long size, int mode) {
  injected_size = size;
  inject = mode;
  int result = names(descriptor);
  inject = INJECT_NONE;
  return result;
}

static void malformed(int anchor) {
  // Positive control: the injector itself yields a parsed name.
  long at = put(0, 1, ".", -1, 0, DT_DIR);
  at = put(at, 2, "..", -1, 0, DT_DIR);
  at = put(at, 3, "ok", -1, 0, DT_REG);
  CHECK(injected_names(anchor, at, INJECT_ONCE) == 3 && output[0] == 2 &&
        memcmp(output + 1, "ok", 2) == 0 && read_descriptor == anchor);

  unsigned count = 0;
  // Each case is built in turn in the same injection buffer.
#define CASE(text, build)                                                      \
  do {                                                                         \
    long end = (build);                                                        \
    if (injected_names(anchor, end, INJECT_ONCE) != FS_DIAG_SUPPORT_ERROR) {   \
      fprintf(stderr, "malformed case accepted: %s\n", text);                  \
      ++failures;                                                              \
    }                                                                          \
    ++count;                                                                   \
  } while (0)
  CASE("truncated header", 10);
  CASE("record shorter than its header", (put(0, 1, "a", -1, 16, DT_REG), 32));
  CASE("record past the read", put(0, 1, "a", -1, 0, DT_REG) - 1);
  CASE("record without NUL", put(0, 1, "abcdefgh", -1, 24, DT_REG));
  CASE("empty name", put(0, 1, "", -1, 0, DT_REG));
  CASE("name with slash", put(0, 1, "a/b", -1, 0, DT_REG));
  char wide[FS_DIAG_DIRECTORY_NAME_BYTES + 2];
  memset(wide, 'w', sizeof(wide) - 1);
  wide[sizeof(wide) - 1] = '\0';
  CASE("name over 255 bytes", put(0, 1, wide, -1, 0, DT_REG));
  CASE("third dot entry",
       put(put(put(0, 1, ".", -1, 0, DT_DIR), 2, "..", -1, 0, DT_DIR), 3, ".",
           -1, 0, DT_DIR));
#ifdef __APPLE__
  CASE("declared name length differs", put(0, 1, "abc", 2, 0, DT_REG));
#endif
#undef CASE
  printf("malformed raw controls: %u refused\n", count);

  // A reported size past the fixed buffer is refused before parsing: valid
  // records run to its end and the last one straddles it.
  at = 0;
  for (unsigned i = 0; at + 112 <= FS_DIAG_DIRECTORY_RAW_BYTES; ++i) {
    char wider[48];
    snprintf(wider, sizeof(wider), "%040u", i);
    at = put(at, i + 1, wider, -1, 0, DT_REG);
  }
  uint16_t straddle = (uint16_t)(FS_DIAG_DIRECTORY_RAW_BYTES - at + 32);
  memset(injected + at, 'z', (size_t)(FS_DIAG_DIRECTORY_RAW_BYTES - at));
  memcpy(injected + at + 16, &straddle, sizeof(straddle));
  injected_size = FS_DIAG_DIRECTORY_RAW_BYTES + 32;
  inject = INJECT_SIZE;
  CHECK(names(anchor) == FS_DIAG_SUPPORT_ERROR);
  injected_size = -1;
  CHECK(names(anchor) == FS_DIAG_SUPPORT_ERROR);
  inject = INJECT_NONE;

  // A directory that never ends: each read repeats a valid record, yet one
  // enumeration still stops after NAMES + 2 records.
  at = put(0, 9, "again", -1, 0, DT_REG);
  CHECK(injected_names(anchor, at, INJECT_ALWAYS) ==
        FS_DIAG_DIRECTORY_UNSUPPORTED);
  CHECK(read_calls == FS_DIAG_DIRECTORY_NAMES + 1);
  // A full raw buffer of minimal records is likewise refused within one read.
  at = 0;
  for (unsigned i = 0; at + 32 <= FS_DIAG_DIRECTORY_RAW_BYTES; ++i) {
    char tiny[8];
    snprintf(tiny, sizeof(tiny), "%u", i);
    at = put(at, i + 1, tiny, -1, 0, DT_REG);
  }
  CHECK(injected_names(anchor, at, INJECT_ONCE) ==
        FS_DIAG_DIRECTORY_UNSUPPORTED);
  CHECK(read_calls == 1);
#ifdef __APPLE__
  // As Libc readdir: inode 0 and whiteout records are not names.
  at = put(0, 0, "deleted", -1, 0, DT_REG);
  at = put(at, 4, "whiteout", -1, 0, DT_WHT);
  at = put(at, 5, "kept", -1, 0, DT_REG);
  CHECK(injected_names(anchor, at, INJECT_ONCE) == 5 && output[0] == 4 &&
        memcmp(output + 1, "kept", 4) == 0);
#endif
}

int main(int argc, char **argv) {
  const char *root = getenv("TMPDIR");
  root = root ? root : "/tmp";
  real_directory(root);
  for (int i = 1; i < argc; ++i)
    real_directory(argv[i]);

  int anchor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  CHECK(anchor >= 0);
  malformed(anchor);

  // Invalid arguments and non-directories fail before any read.
  char path[512];
  snprintf(path, sizeof(path), "%s/fsfileXXXXXX", root);
  int file = mkstemp(path);
  CHECK(file >= 0);
  read_calls = 0;
  CHECK(fs_diag_directory_names(file, output, sizeof(output)) ==
        FS_DIAG_SUPPORT_ERROR);
  CHECK(fs_diag_directory_names(-1, output, sizeof(output)) ==
        FS_DIAG_SUPPORT_ERROR);
  CHECK(fs_diag_directory_names(anchor, NULL, sizeof(output)) ==
        FS_DIAG_SUPPORT_ERROR);
  CHECK(fs_diag_directory_names(anchor, output,
                                FS_DIAG_DIRECTORY_OUTPUT_BYTES - 1) ==
        FS_DIAG_SUPPORT_ERROR);
  int closed = dup(anchor);
  close(closed);
  CHECK(fs_diag_directory_names(closed, output, sizeof(output)) ==
        FS_DIAG_SUPPORT_ERROR);
  CHECK(read_calls == 0);
#ifdef __APPLE__
  // A union stack is refused before any raw read; fstatfs failure is an error.
  force_union = 1;
  CHECK(names(anchor) == FS_DIAG_DIRECTORY_UNSUPPORTED && read_calls == 0);
  force_union = 0;
  fail_fstatfs = 1;
  CHECK(names(anchor) == FS_DIAG_SUPPORT_ERROR && read_calls == 0);
  fail_fstatfs = 0;
#endif

  // No libc directory stream was used; the interposer does observe a call.
  CHECK(stream_calls == 0);
  CHECK(fdopendir(anchor) == NULL && stream_calls == 1);
  printf("raw reads requested %d bytes each; libc stream calls by enumerator: "
         "0\n",
         FS_DIAG_DIRECTORY_RAW_BYTES);

  close(file);
  unlink(path);
  close(anchor);
  if (failures)
    fprintf(stderr, "%d diagnostic directory checks failed\n", failures);
  return failures != 0;
}
