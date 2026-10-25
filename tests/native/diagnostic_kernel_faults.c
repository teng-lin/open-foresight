#define _DARWIN_C_SOURCE
#if !defined(__APPLE__) || !defined(__arm64__)
#error Darwin-only private namespace failure fixture
#endif
#if !defined(FS_DIAG_TEST_CONTEXT) || FS_DIAG_TEST_CONTEXT != 1 ||             \
    !defined(FS_DIAG_FIXTURE_BASE) || !defined(FS_DIAG_FIXTURE_PREFIX)
#error Compile an explicit private fixture namespace
#endif

#include "diagnostic_kernel.h"
#include <dirent.h>
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

static int metadata_at(int parent, const char *name, struct stat *metadata) {
  if (fstatat(parent, name, metadata, AT_SYMLINK_NOFOLLOW) == 0)
    return 1;
  CHECK(errno == ENOENT);
  return 0;
}

static int fixture_directory(int parent, const char *name) {
  int descriptor =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  CHECK(descriptor >= 0 && directory_metadata(descriptor, geteuid(), 0700));
  CHECK(supported_mount(descriptor));
  return descriptor;
}

static void only_known_entry(int descriptor, const char *allowed) {
  int copied = fcntl(descriptor, F_DUPFD_CLOEXEC, 11);
  CHECK(copied >= 0);
  DIR *directory = fdopendir(copied);
  CHECK(directory != NULL);
  unsigned entries = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (entry == NULL) {
      CHECK(errno == 0);
      break;
    }
    CHECK(++entries <= 3);
    CHECK(strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 ||
          (allowed != NULL && strcmp(entry->d_name, allowed) == 0));
  }
  CHECK(closedir(directory) == 0);
}

static void unchanged(int parent, const char *name, const struct stat *prior) {
  struct stat now;
  CHECK(metadata_at(parent, name, &now));
  CHECK(now.st_dev == prior->st_dev && now.st_ino == prior->st_ino &&
        now.st_uid == prior->st_uid && now.st_mode == prior->st_mode);
  if (!S_ISDIR(now.st_mode))
    CHECK(now.st_size == prior->st_size);
}

static unsigned known_alias(int parent, const char *name,
                            const struct stat *alias, const struct stat *held,
                            int has_held, const char *target) {
  CHECK(has_held && alias->st_uid == geteuid());
  if (S_ISREG(alias->st_mode)) {
    CHECK((alias->st_mode & 07777) == 0600 && alias->st_size == 0);
    CHECK(alias->st_dev == held->st_dev && alias->st_ino == held->st_ino);
    return 1;
  }
  CHECK(S_ISLNK(alias->st_mode) && alias->st_nlink == 1);
  char bytes[1024];
  ssize_t size = readlinkat(parent, name, bytes, sizeof(bytes));
  CHECK(size >= 0 && (size_t)size == strlen(target));
  CHECK(memcmp(bytes, target, (size_t)size) == 0);
  return 0;
}

// A persistent private directory lease serializes all cooperating invocations.
// Cleanup recognizes only the exact names and alias graph planted below; it
// never recursively removes an entry or opens an ordinary candidate for data.
static int prepare_fixture(const char *root_name, const char *name) {
  CHECK(sizeof(kernel_prefix) >= 3 && sizeof(kernel_prefix) <= 13);
  CHECK(kernel_prefix[0] == '/' && strcmp(kernel_prefix, "/ofdg1") != 0);
  for (size_t i = 1; i != sizeof(kernel_prefix) - 1; ++i)
    CHECK((kernel_prefix[i] >= 'a' && kernel_prefix[i] <= 'z') ||
          (kernel_prefix[i] >= '0' && kernel_prefix[i] <= '9'));
  CHECK(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0 || errno == EEXIST);
  int base = fixture_directory(AT_FDCWD, FS_DIAG_FIXTURE_BASE);
  CHECK(flock(base, LOCK_EX | LOCK_NB) == 0);
  struct stat held = {0}, root = {0}, slot = {0};
  int has_held = metadata_at(base, "held-lock", &held);
  if (has_held)
    CHECK(S_ISREG(held.st_mode) && held.st_uid == geteuid() &&
          (held.st_mode & 07777) == 0600 && held.st_size == 0);
  char target[1024];
  int length =
      snprintf(target, sizeof(target), "%s/held-lock", FS_DIAG_FIXTURE_BASE);
  CHECK(length > 0 && (size_t)length < sizeof(target));
  int has_root = metadata_at(base, root_name, &root);
  int root_fd = -1, slot_fd = -1, has_slot = 0;
  unsigned aliases = 0;
  if (has_root) {
    if (S_ISDIR(root.st_mode)) {
      root_fd = fixture_directory(base, root_name);
      unchanged(base, root_name, &root);
      only_known_entry(root_fd, "00");
      has_slot = metadata_at(root_fd, "00", &slot);
      if (has_slot) {
        if (S_ISDIR(slot.st_mode)) {
          slot_fd = fixture_directory(root_fd, "00");
          unchanged(root_fd, "00", &slot);
          only_known_entry(slot_fd, NULL);
        } else {
          aliases += known_alias(root_fd, "00", &slot, &held, has_held, target);
        }
      }
    } else {
      aliases += known_alias(base, root_name, &root, &held, has_held, target);
    }
  }
  if (has_held)
    CHECK(held.st_nlink == 1 + aliases);
  int object = shm_open(name, O_RDONLY, 0);
  if (object >= 0) {
    struct stat metadata;
    CHECK(fstat(object, &metadata) == 0 && (metadata.st_mode & S_IFMT) == 0);
    CHECK(metadata.st_uid == geteuid() && metadata.st_nlink == 0);
    CHECK((metadata.st_mode & 07777) == 0600 ||
          (metadata.st_mode & 07777) == 0400);
    CHECK(metadata.st_size == 0 || metadata.st_size == FS_DIAG_PAGE_BYTES);
  } else {
    CHECK(errno == ENOENT);
  }
  // All known candidates are validated before any destructive operation.
  if (has_slot) {
    unchanged(root_fd, "00", &slot);
    CHECK(unlinkat(root_fd, "00", S_ISDIR(slot.st_mode) ? AT_REMOVEDIR : 0) ==
          0);
    if (slot_fd >= 0)
      CHECK(close(slot_fd) == 0);
  }
  if (has_root) {
    unchanged(base, root_name, &root);
    CHECK(unlinkat(base, root_name, S_ISDIR(root.st_mode) ? AT_REMOVEDIR : 0) ==
          0);
    if (root_fd >= 0)
      CHECK(close(root_fd) == 0);
  }
  if (has_held) {
    unchanged(base, "held-lock", &held);
    struct stat now;
    CHECK(metadata_at(base, "held-lock", &now) && now.st_nlink == 1);
    CHECK(unlinkat(base, "held-lock", 0) == 0);
  }
  if (object >= 0)
    CHECK(shm_unlink(name) == 0 && close(object) == 0);
  return base;
}

static void lease_excludes_contender(void) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    int descriptor = fixture_directory(AT_FDCWD, FS_DIAG_FIXTURE_BASE);
    errno = 0;
    CHECK(flock(descriptor, LOCK_EX | LOCK_NB) == -1);
    CHECK(errno == EWOULDBLOCK || errno == EAGAIN);
    CHECK(close(descriptor) == 0);
    _exit(0);
  }
  joined(child, 0);
}

static void leave_interrupted_fixture(int base, const char *root_name,
                                      const char *name, const char *mode) {
  int held =
      openat(base, "held-lock", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
  CHECK(held >= 0);
  char target[1024];
  int length =
      snprintf(target, sizeof(target), "%s/held-lock", FS_DIAG_FIXTURE_BASE);
  CHECK(length > 0 && (size_t)length < sizeof(target));
  int parent = base;
  const char *alias = root_name;
  if (strncmp(mode, "slot-", 5) == 0) {
    CHECK(mkdirat(base, root_name, 0700) == 0);
    parent = fixture_directory(base, root_name);
    alias = "00";
    mode += 5;
  } else {
    CHECK(strncmp(mode, "root-", 5) == 0);
    mode += 5;
  }
  if (strcmp(mode, "hardlink") == 0)
    CHECK(linkat(base, "held-lock", parent, alias, 0) == 0);
  else {
    CHECK(strcmp(mode, "symlink") == 0);
    CHECK(symlinkat(target, parent, alias) == 0);
  }
  int object = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
  CHECK(object >= 0 && ftruncate(object, FS_DIAG_PAGE_BYTES) == 0);
  // Emulate interruption without fixture teardown: the OS releases locks and
  // descriptors, while exact planted names remain for the next invocation.
  _exit(0);
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

int main(int argc, char **argv) {
  alarm(20);
  CHECK(argc == 1 || argc == 2);
  char root[1024], slot[1100], name[32];
  int length = snprintf(root, sizeof(root), "%s/of-diag-v1-%lu",
                        FS_DIAG_FIXTURE_BASE, (unsigned long)geteuid());
  CHECK(length > 0 && (size_t)length < sizeof(root));
  length = snprintf(slot, sizeof(slot), "%s/00", root);
  CHECK(length > 0 && (size_t)length < sizeof(slot));
  length = snprintf(name, sizeof(name), "%s.%lu.00", FS_DIAG_FIXTURE_PREFIX,
                    (unsigned long)geteuid());
  CHECK(length > 0 && (size_t)length < sizeof(name));
  char root_name[48];
  length = snprintf(root_name, sizeof(root_name), "of-diag-v1-%lu",
                    (unsigned long)geteuid());
  CHECK(length > 0 && (size_t)length < sizeof(root_name));
  int fixture_lease = prepare_fixture(root_name, name);
  if (argc == 2 && strcmp(argv[1], "cleanup-fixture") == 0) {
    CHECK(close(fixture_lease) == 0);
    return 0;
  }
  lease_excludes_contender();
  if (argc == 2)
    leave_interrupted_fixture(fixture_lease, root_name, name,
                              strcmp(argv[1], "leave-interrupted-fixture") == 0
                                  ? "slot-hardlink"
                                  : argv[1]);
  reject_file_and_symlink(root, slot);
  low_descriptor_failures();
  failed_unlink_retains_one_lease(slot, name);
  crash_reclaim(name);
  CHECK(rmdir(slot) == 0 && rmdir(root) == 0);
  CHECK(close(fixture_lease) == 0);
  puts("private allocator file/symlink, low-FD, retained-lease and "
       "crash-reclaim controls passed");
  return 0;
}
