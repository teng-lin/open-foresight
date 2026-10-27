#define _GNU_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_inherited.h"
#include "diagnostic_kernel.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
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

// CTest versions may inherit their own log FD without CLOEXEC. Establish the
// fixture's clean exec baseline before creating intentional foreign-FD cases.
static void isolate_harness_descriptors(void) {
#ifdef __linux__
  DIR *directory = opendir("/proc/self/fd");
#else
  DIR *directory = opendir("/dev/fd");
#endif
  CHECK(directory != NULL);
  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    char *end = NULL;
    errno = 0;
    long descriptor = strtol(entry->d_name, &end, 10);
    if (errno != 0 || end == entry->d_name || *end != '\0' || descriptor < 3 ||
        descriptor > INT_MAX)
      continue;
    int flags = fcntl((int)descriptor, F_GETFD);
    CHECK(flags >= 0 &&
          fcntl((int)descriptor, F_SETFD, flags | FD_CLOEXEC) == 0);
  }
  CHECK(closedir(directory) == 0);
}

static void raise_soft_limit(rlim_t required) {
  struct rlimit limit;
  CHECK(getrlimit(RLIMIT_NOFILE, &limit) == 0);
  CHECK(limit.rlim_max >= required);
  if (limit.rlim_cur < required) {
    limit.rlim_cur = required;
    CHECK(setrlimit(RLIMIT_NOFILE, &limit) == 0);
  }
}

static void joined(pid_t child) {
  int status;
  CHECK(child > 0 && waitpid(child, &status, 0) == child);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    fprintf(stderr, "private child status=%d\n", status);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static int contender_can_lock(int descriptor) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(10);
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    int result = fcntl(descriptor, F_SETLK, &lock);
    if (result == 0)
      _exit(0);
    _exit(errno == EAGAIN || errno == EACCES ? 1 : 2);
  }
  int status;
  CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status));
  CHECK(WEXITSTATUS(status) <= 1);
  return WEXITSTATUS(status) == 0;
}

static void ordinary_candidate(const char *root) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(10);
    char path[1024];
    int size = snprintf(path, sizeof(path), "%s/inherited-lock-XXXXXX", root);
    CHECK(size > 0 && (size_t)size < sizeof(path));
    int original = mkstemp(path);
    CHECK(original >= 0 && ftruncate(original, FS_DIAG_PAGE_BYTES) == 0);
    if (original != FS_DIAG_CHILD_FD) {
      CHECK(dup2(original, FS_DIAG_CHILD_FD) == FS_DIAG_CHILD_FD);
      CHECK(close(original) == 0);
    }
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    CHECK(fcntl(FS_DIAG_CHILD_FD, F_SETLK, &lock) == 0);
    CHECK(!contender_can_lock(FS_DIAG_CHILD_FD));
    int flags = fcntl(FS_DIAG_CHILD_FD, F_GETFD);
    fs_diag_page *page = (void *)1;
    CHECK(fs_diag_inherited_page_open(&page) == FS_DIAG_INHERITED_UNSAFE);
    CHECK(page == NULL && fcntl(FS_DIAG_CHILD_FD, F_GETFD) == flags);
    CHECK(!contender_can_lock(FS_DIAG_CHILD_FD));
    CHECK(close(FS_DIAG_CHILD_FD) == 0 && unlink(path) == 0);
    _exit(0);
  }
  joined(child);
}

static void exec_case(const char *executable, const char *mode,
                      fs_diag_kernel_page *page, int foreign) {
  pid_t child = fork();
  CHECK(child >= 0);
  if (child == 0) {
    alarm(10);
    CHECK(dup2(page->descriptor, FS_DIAG_CHILD_FD) == FS_DIAG_CHILD_FD);
    int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    int output = open("/dev/null", O_WRONLY | O_CLOEXEC);
    CHECK(input >= 3 && output >= 3);
    CHECK(dup2(input, 0) == 0);
    if (strcmp(mode, "stdio") == 0)
      CHECK(dup2(input, 1) == 1); // Wrong access mode, even under >/dev/null.
    else
      CHECK(dup2(output, 1) == 1);
    CHECK(dup2(output, 2) == 2);
    CHECK(close(input) == 0 && close(output) == 0);
    if (strcmp(mode, "foreign") == 0) {
      raise_soft_limit(5004);
      CHECK(dup2(foreign, 5003) == 5003);
      struct rlimit limit;
      CHECK(getrlimit(RLIMIT_NOFILE, &limit) == 0);
      limit.rlim_cur = 128;
      CHECK(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    }
    execl(executable, executable, "child", mode, (char *)NULL);
    _exit(89);
  }
  joined(child);
  if (strcmp(mode, "clean") == 0)
    CHECK(atomic_load(&page->mapping->header.child_pid) == (uint64_t)child);
}

static int child_mode(const char *mode) {
  alarm(10);
  if (strcmp(mode, "limit") == 0) {
    raise_soft_limit(4096);
    for (int index = 0; index != FS_DIAG_DESCRIPTOR_LIMIT; ++index)
      CHECK(open("/dev/null", O_RDONLY | O_CLOEXEC) >= 0);
  }
  fs_diag_page *page = (void *)1;
  int outcome = fs_diag_inherited_page_open(&page);
  int expected = strcmp(mode, "limit") == 0   ? FS_DIAG_INHERITED_LIMIT
                 : strcmp(mode, "clean") == 0 ? FS_DIAG_INHERITED_OK
                                              : FS_DIAG_INHERITED_UNSAFE;
  if (outcome != expected)
    return 90 + outcome;
  errno = 0;
  if (fcntl(FS_DIAG_CHILD_FD, F_GETFD) != -1 || errno != EBADF)
    return 95;
  if (outcome == FS_DIAG_INHERITED_OK) {
    if (page == NULL)
      return 96;
    atomic_store(&page->header.child_pid, (uint64_t)getpid());
    if (munmap(page, FS_DIAG_PAGE_BYTES) != 0)
      return 97;
  } else if (page != NULL) {
    return 98;
  }
  if (strcmp(mode, "foreign") == 0 && fcntl(5003, F_GETFD) != 0)
    return 99; // Refusal must not close the unrelated inherited candidate.
  return 0;
}

int main(int argc, char **argv) {
  alarm(15);
  if (argc == 3 && strcmp(argv[1], "child") == 0)
    return child_mode(argv[2]);
  CHECK(argc == 2 && argv[0][0] == '/' && argv[1][0] == '/');
#ifdef __APPLE__
  // The backend is compiled with a separate, explicit nonproduct namespace.
  CHECK(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0 || errno == EEXIST);
#endif
  isolate_harness_descriptors();
  ordinary_candidate(argv[1]);
  fs_diag_kernel_page page;
  CHECK(fs_diag_kernel_page_create(&page) == FS_DIAG_KERNEL_OK);
  char path[1024];
  int size =
      snprintf(path, sizeof(path), "%s/inherited-foreign-XXXXXX", argv[1]);
  CHECK(size > 0 && (size_t)size < sizeof(path));
  int foreign = mkstemp(path);
  CHECK(foreign >= 0 && fcntl(foreign, F_SETFD, FD_CLOEXEC) == 0);
  struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
  CHECK(fcntl(foreign, F_SETLK, &lock) == 0);
  CHECK(!contender_can_lock(foreign));
  const char *modes[] = {"clean", "foreign", "limit", "stdio"};
  for (unsigned index = 0; index != sizeof(modes) / sizeof(modes[0]); ++index) {
    printf("inherited gate case=%s\n", modes[index]);
    fflush(stdout);
    exec_case(argv[0], modes[index], &page, foreign);
    CHECK(!contender_can_lock(foreign));
  }
  CHECK(close(foreign) == 0 && unlink(path) == 0);
  CHECK(munmap(page.mapping, FS_DIAG_PAGE_BYTES) == 0);
  CHECK(close(page.descriptor) == 0);
  puts("inherited gate mapping, foreign/high-FD, limit, stdio and lock "
       "controls passed");
  return 0;
}
