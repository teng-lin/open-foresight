#define _GNU_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_kernel.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
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
      fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__,       \
              #value);                                                         \
      abort();                                                                 \
    }                                                                          \
  } while (0)

static void joined(pid_t child) {
  int status;
  CHECK(child > 0 && waitpid(child, &status, 0) == child);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void release(fs_diag_kernel_page *page) {
  CHECK(munmap(page->mapping, FS_DIAG_PAGE_BYTES) == 0);
  CHECK(close(page->descriptor) == 0);
}

static void size_is_fixed(int descriptor) {
  CHECK(ftruncate(descriptor, 0) == -1);
  CHECK(ftruncate(descriptor, FS_DIAG_PAGE_BYTES / 2) == -1);
  CHECK(ftruncate(descriptor, FS_DIAG_PAGE_BYTES * 2) == -1);
  struct stat metadata;
  CHECK(fstat(descriptor, &metadata) == 0);
  CHECK(metadata.st_size == FS_DIAG_PAGE_BYTES);
}

static void allocation(const char *executable) {
  fs_diag_kernel_page page;
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  CHECK(page.descriptor >= 11 && page.mapping != NULL);
  CHECK(fcntl(page.descriptor, F_GETFD) == FD_CLOEXEC);
  CHECK((fcntl(page.descriptor, F_GETFL) & O_ACCMODE) == O_RDWR);
  struct stat metadata;
  CHECK(fstat(page.descriptor, &metadata) == 0);
  CHECK(metadata.st_uid == geteuid() && metadata.st_nlink == 0);
  CHECK((metadata.st_mode & 07777) == 0600);
  CHECK(metadata.st_size == FS_DIAG_PAGE_BYTES);
  const unsigned char *bytes = (const unsigned char *)page.mapping;
  for (size_t i = 0; i != FS_DIAG_PAGE_BYTES; ++i)
    CHECK(bytes[i] == 0);
  CHECK(fs_diag_page_supported(page.mapping));
  size_is_fixed(page.descriptor);
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    size_is_fixed(page.descriptor);
    atomic_store(&page.mapping->header.child_pid, (uint64_t)getpid());
    _exit(0);
  }
  joined(child);
  CHECK(atomic_load(&page.mapping->header.child_pid) == (uint64_t)child);

  char descriptor[24];
  CHECK(snprintf(descriptor, sizeof(descriptor), "%d", page.descriptor) > 0);
  child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    execl(executable, executable, "closed", descriptor, (char *)NULL);
    _exit(91);
  }
  joined(child);
  child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    CHECK(dup2(page.descriptor, FS_DIAG_CHILD_FD) == FS_DIAG_CHILD_FD);
    CHECK(fcntl(FS_DIAG_CHILD_FD, F_SETFD, 0) == 0);
    execl(executable, executable, "inherited", "10", (char *)NULL);
    _exit(92);
  }
  joined(child);
  release(&page);
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

static void ordinary_file_lock(const char *root) {
  char path[1024], alias[1024];
  int count = snprintf(path, sizeof(path), "%s/kernel-lock-XXXXXX", root);
  CHECK(count > 0 && (size_t)count < sizeof(path));
  int descriptor = mkstemp(path);
  CHECK(descriptor >= 0);
  count = snprintf(alias, sizeof(alias), "%s-alias", path);
  CHECK(count > 0 && (size_t)count < sizeof(alias));
  CHECK(link(path, alias) == 0);
  struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
  CHECK(fcntl(descriptor, F_SETLK, &lock) == 0);
  CHECK(!contender_can_lock(descriptor));
  // Prove this fixture detects the POSIX close-any-alias failure mode.
  int opened = open(alias, O_RDONLY);
  CHECK(opened >= 0 && close(opened) == 0);
  CHECK(contender_can_lock(descriptor));
  CHECK(fcntl(descriptor, F_SETLK, &lock) == 0);
  fs_diag_kernel_page page;
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  CHECK(!contender_can_lock(descriptor));
  release(&page);
  CHECK(!contender_can_lock(descriptor));
  CHECK(close(descriptor) == 0 && unlink(alias) == 0 && unlink(path) == 0);
}

#ifdef __APPLE__
#if !defined(FS_DIAG_TEST_CONTEXT) || FS_DIAG_TEST_CONTEXT != 1 ||             \
    !defined(FS_DIAG_FIXTURE_BASE) || !defined(FS_DIAG_FIXTURE_PREFIX)
#error Darwin allocator tests require a private compiled namespace
#endif

static void private_namespace(void) {
  char root[1024], path[1100], name[32];
  CHECK(snprintf(root, sizeof(root), "%s/of-diag-v1-%lu", FS_DIAG_FIXTURE_BASE,
                 (unsigned long)geteuid()) > 0);
  CHECK(snprintf(name, sizeof(name), "%s.%lu.00", FS_DIAG_FIXTURE_PREFIX,
                 (unsigned long)geteuid()) > 0);
  fs_diag_kernel_page page;
  // An unexpected ordinary-file candidate is never data-opened or closed by
  // the allocator, even when it is an alias of a held application lock.
  CHECK(snprintf(path, sizeof(path), "%s/unexpected", root) > 0);
  int ordinary = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
  CHECK(ordinary >= 0);
  struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
  CHECK(fcntl(ordinary, F_SETLK, &lock) == 0);
  CHECK(fs_diag_kernel_page_create(&page) ==
        FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
  CHECK(!contender_can_lock(ordinary));
  CHECK(close(ordinary) == 0 && unlink(path) == 0);

  CHECK(snprintf(path, sizeof(path), "%s/00/entry", root) > 0);
  ordinary = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
  CHECK(ordinary >= 0);
  CHECK(fs_diag_kernel_page_create(&page) ==
        FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
  CHECK(close(ordinary) == 0 && unlink(path) == 0);

  int slots[64];
  for (unsigned index = 0; index != 64; ++index) {
    CHECK(snprintf(path, sizeof(path), "%s/%02u", root, index) > 0);
    CHECK(mkdir(path, 0700) == 0 || errno == EEXIST);
    slots[index] = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    CHECK(slots[index] >= 0 && flock(slots[index], LOCK_EX | LOCK_NB) == 0);
  }
  CHECK(fs_diag_kernel_page_create(&page) ==
        FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
  for (unsigned index = 0; index != 64; ++index)
    CHECK(close(slots[index]) == 0);

  int stale = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
  CHECK(stale >= 0);
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  struct stat old;
  CHECK(fstat(stale, &old) == 0 && old.st_size == 0);
  CHECK(close(stale) == 0);
  release(&page);
  errno = 0;
  CHECK(shm_open(name, O_RDWR, 0) == -1 && errno == ENOENT);

  // A reserved but unsafe stale object must remain intact for its owner.
  stale = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0400);
  CHECK(stale >= 0);
  CHECK(fs_diag_kernel_page_create(&page) ==
        FS_DIAG_KERNEL_STAGING_UNAVAILABLE);
  CHECK(fstat(stale, &old) == 0 && (old.st_mode & 07777) == 0400);
  int existing = shm_open(name, O_RDONLY, 0);
  CHECK(existing >= 0 && close(existing) == 0);
  CHECK(close(stale) == 0 && shm_unlink(name) == 0);
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  release(&page);
}
#endif

int main(int argc, char **argv) {
  alarm(15);
  if (argc == 3 && strcmp(argv[1], "closed") == 0) {
    int descriptor = atoi(argv[2]);
    CHECK(descriptor >= 11);
    errno = 0;
    CHECK(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "inherited") == 0) {
    CHECK(strcmp(argv[2], "10") == 0);
    size_is_fixed(FS_DIAG_CHILD_FD);
    return 0;
  }
  CHECK(argc == 2 && argv[0][0] == '/' && argv[1][0] == '/');
#ifdef __APPLE__
  CHECK(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0 || errno == EEXIST);
#endif
  CHECK(fs_diag_kernel_page_create(NULL) == FS_DIAG_KERNEL_UNSUPPORTED);
  allocation(argv[0]);
  ordinary_file_lock(argv[1]);
#ifdef __APPLE__
  private_namespace();
#endif
  for (unsigned mask = 1; mask != 8; ++mask) {
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
      for (int descriptor = 0; descriptor != 3; ++descriptor)
        if (mask & (1U << descriptor))
          close(descriptor);
      allocation(argv[0]);
      _exit(0);
    }
    joined(child);
  }
  puts("kernel allocation, fixed size, inheritance, low stdio and lock "
       "controls passed");
  return 0;
}
