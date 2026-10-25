#define _DARWIN_C_SOURCE
#if !defined(__APPLE__) || !defined(__arm64__)
#error Darwin-only private namespace failure fixture
#endif
#if !defined(FS_DIAG_TEST_CONTEXT) || FS_DIAG_TEST_CONTEXT != 1 ||             \
    !defined(FS_DIAG_FIXTURE_BASE) || !defined(FS_DIAG_FIXTURE_PREFIX)
#error Compile an explicit private fixture namespace
#endif

#include "diagnostic_kernel.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(value)                                                           \
  do {                                                                         \
    if (!(value)) {                                                            \
      fprintf(stderr, "check failed %s:%d: %s errno=%d\n", __FILE__, __LINE__, \
              #value, errno);                                                  \
      abort();                                                                 \
    }                                                                          \
  } while (0)

static int fs_diag_fault_shm_open(const char *, int, ...);
static int fs_diag_fault_shm_unlink(const char *);
static int fs_diag_fault_fcntl(int, int, ...);
// Compile the unchanged implementation in this test translation unit. The
// substitutions affect only its system calls, never a production target.
#define shm_open fs_diag_fault_shm_open
#define shm_unlink fs_diag_fault_shm_unlink
#define fcntl fs_diag_fault_fcntl
#include "../../native/diagnostic_kernel_darwin.c"
#undef fcntl
#undef shm_unlink
#undef shm_open

static int fail_unlink, crash_after_create, fail_directory_dup, fail_object_dup;
static int fresh_object = -1;
static unsigned unlink_calls;

static int fs_diag_fault_shm_open(const char *name, int flags, ...) {
  va_list arguments;
  va_start(arguments, flags);
  mode_t mode = (mode_t)va_arg(arguments, int);
  va_end(arguments);
  int descriptor = shm_open(name, flags, mode);
  if (descriptor >= 0 && (flags & (O_CREAT | O_EXCL)) == (O_CREAT | O_EXCL)) {
    fresh_object = descriptor;
    if (crash_after_create)
      _exit(73);
  }
  return descriptor;
}

static int fs_diag_fault_shm_unlink(const char *name) {
  ++unlink_calls;
  if (fail_unlink) {
    errno = EACCES;
    return -1;
  }
  return shm_unlink(name);
}

static int fs_diag_fault_fcntl(int descriptor, int command, ...) {
  if (command == F_DUPFD_CLOEXEC) {
    va_list arguments;
    va_start(arguments, command);
    int minimum = va_arg(arguments, int);
    va_end(arguments);
    if (fail_directory_dup || (fail_object_dup && descriptor == fresh_object)) {
      errno = EMFILE;
      return -1;
    }
    return fcntl(descriptor, command, minimum);
  }
  CHECK(command == F_GETFD || command == F_GETFL);
  return fcntl(descriptor, command);
}

static unsigned descriptors(void) {
  unsigned total = 0;
  // All fixture-owned descriptors are low; count without opening any file or
  // directory candidate, so the observer cannot release a POSIX lock.
  for (int descriptor = 0; descriptor != 256; ++descriptor) {
    errno = 0;
    int flags = fcntl(descriptor, F_GETFD);
    CHECK(flags >= 0 || errno == EBADF);
    total += flags >= 0;
  }
  return total;
}

static void joined(pid_t child, int expected) {
  int status;
  CHECK(child > 0 && waitpid(child, &status, 0) == child);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == expected);
}

static void release(fs_diag_kernel_page *page) {
  CHECK(munmap(page->mapping, FS_DIAG_PAGE_BYTES) == 0);
  CHECK(close(page->descriptor) == 0);
}

static void succeeds(void) {
  fs_diag_kernel_page page;
  unsigned before = descriptors();
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  release(&page);
  CHECK(descriptors() == before);
}

static void refuses(void) {
  fs_diag_kernel_page page = {.mapping = (void *)1, .descriptor = 123};
  unsigned before = descriptors();
  CHECK(fs_diag_kernel_page_create(&page) ==
        FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
  CHECK(page.mapping == NULL && page.descriptor == -1);
  CHECK(descriptors() == before);
}

static int contender_can_lock(int descriptor) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    int result = fcntl(descriptor, F_SETLK, &lock);
    if (result == 0)
      _exit(0);
    _exit(errno == EACCES || errno == EAGAIN ? 1 : 2);
  }
  int status;
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status));
  CHECK(WEXITSTATUS(status) <= 1);
  return WEXITSTATUS(status) == 0;
}

static void reject_file_and_symlink(const char *root, const char *slot) {
  char target[1024];
  int length =
      snprintf(target, sizeof(target), "%s/held-lock", FS_DIAG_FIXTURE_BASE);
  CHECK(length > 0 && (size_t)length < sizeof(target));
  int descriptor = open(target, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
  CHECK(descriptor >= 0);
  struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
  CHECK(fcntl(descriptor, F_SETLK, &lock) == 0);
  CHECK(!contender_can_lock(descriptor));
  const char *candidates[] = {root, slot};
  for (unsigned index = 0; index != 2; ++index) {
    if (index == 1)
      CHECK(mkdir(root, 0700) == 0);
    CHECK(link(target, candidates[index]) == 0);
    refuses();
    CHECK(!contender_can_lock(descriptor));
    CHECK(unlink(candidates[index]) == 0);
    CHECK(symlink(target, candidates[index]) == 0);
    refuses();
    CHECK(!contender_can_lock(descriptor));
    CHECK(unlink(candidates[index]) == 0);
  }
  CHECK(close(descriptor) == 0 && unlink(target) == 0);
  succeeds();
}

static void low_descriptor_failures(void) {
  for (unsigned object = 0; object != 2; ++object) {
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
      CHECK(close(STDIN_FILENO) == 0);
      if (object)
        fail_object_dup = 1;
      else
        fail_directory_dup = 1;
      refuses();
      errno = 0;
      CHECK(fcntl(STDIN_FILENO, F_GETFD) == -1 && errno == EBADF);
      _exit(0);
    }
    joined(child, 0);
    succeeds();
  }
}

static void failed_unlink_retains_one_lease(const char *slot,
                                            const char *name) {
  int ready[2], retire[2];
  CHECK(pipe(ready) == 0 && pipe(retire) == 0);
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    CHECK(close(ready[0]) == 0 && close(retire[1]) == 0);
    fail_unlink = 1;
    unlink_calls = 0;
    fs_diag_kernel_page page;
    unsigned before = descriptors();
    CHECK(fs_diag_kernel_page_create(&page) ==
          FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
    CHECK(page.mapping == NULL && page.descriptor == -1);
    CHECK(unlink_calls == 1);
    CHECK(descriptors() == before + 1);
    CHECK(write(ready[1], "r", 1) == 1);
    char byte;
    CHECK(read(retire[0], &byte, 1) == 1 && byte == 'x');
    _exit(0);
  }
  CHECK(close(ready[1]) == 0 && close(retire[0]) == 0);
  char byte;
  CHECK(read(ready[0], &byte, 1) == 1 && byte == 'r');
  int descriptor = open(slot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  CHECK(descriptor >= 0);
  errno = 0;
  CHECK(flock(descriptor, LOCK_EX | LOCK_NB) == -1);
  CHECK(errno == EWOULDBLOCK || errno == EAGAIN);
  CHECK(close(descriptor) == 0);
  int stale = shm_open(name, O_RDWR, 0);
  CHECK(stale >= 0);
  struct stat metadata;
  CHECK(fstat(stale, &metadata) == 0 && metadata.st_size == FS_DIAG_PAGE_BYTES);
  CHECK(write(retire[1], "x", 1) == 1);
  joined(child, 0);
  CHECK(close(ready[0]) == 0 && close(retire[1]) == 0);
  succeeds();
  CHECK(fstat(stale, &metadata) == 0 && metadata.st_size == FS_DIAG_PAGE_BYTES);
  CHECK(close(stale) == 0);
  errno = 0;
  CHECK(shm_open(name, O_RDWR, 0) == -1 && errno == ENOENT);
}

static void crash_reclaim(const char *name) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    crash_after_create = 1;
    fs_diag_kernel_page page;
    fs_diag_kernel_page_create(&page);
    _exit(74);
  }
  joined(child, 73);
  int stale = shm_open(name, O_RDWR, 0);
  CHECK(stale >= 0);
  struct stat metadata;
  CHECK(fstat(stale, &metadata) == 0 && metadata.st_size == 0);
  succeeds();
  CHECK(fstat(stale, &metadata) == 0 && metadata.st_size == 0);
  CHECK(close(stale) == 0);
  errno = 0;
  CHECK(shm_open(name, O_RDWR, 0) == -1 && errno == ENOENT);
}

int main(void) {
  alarm(20);
  CHECK(kernel_prefix[0] == '/' && strcmp(kernel_prefix, "/ofdg1") != 0);
  CHECK(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0);
  char root[1024], slot[1100], name[32];
  int length = snprintf(root, sizeof(root), "%s/of-diag-v1-%lu",
                        FS_DIAG_FIXTURE_BASE, (unsigned long)geteuid());
  CHECK(length > 0 && (size_t)length < sizeof(root));
  length = snprintf(slot, sizeof(slot), "%s/00", root);
  CHECK(length > 0 && (size_t)length < sizeof(slot));
  length = snprintf(name, sizeof(name), "%s.%lu.00", FS_DIAG_FIXTURE_PREFIX,
                    (unsigned long)geteuid());
  CHECK(length > 0 && (size_t)length < sizeof(name));
  reject_file_and_symlink(root, slot);
  low_descriptor_failures();
  failed_unlink_retains_one_lease(slot, name);
  crash_reclaim(name);
  CHECK(rmdir(slot) == 0 && rmdir(root) == 0 &&
        rmdir(FS_DIAG_FIXTURE_BASE) == 0);
  puts("private allocator file/symlink, low-FD, retained-lease and "
       "crash-reclaim controls passed");
  return 0;
}
