#define _GNU_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_protocol.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
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
      fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__,       \
              #value);                                                         \
      abort();                                                                 \
    }                                                                          \
  } while (0)

static const char identity[] = FORESIGHT_DIAGNOSTIC_NATIVE_ID;
static int probe_fd = 5003;
extern char **environ;

static int probe(int leaked_fd) {
  fs_diag_page *page = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE,
                            MAP_SHARED, FS_DIAG_CHILD_FD, 0);
  if (page == MAP_FAILED)
    return 71;
  if (getppid() != (pid_t)page->header.application_pid || getpgrp() != getpid())
    return 72;
  if (fcntl(leaked_fd, F_GETFD) != -1 || fcntl(9, F_GETFD) != -1 ||
      fcntl(FS_DIAG_CHILD_FD, F_GETFD) != 0)
    return 73;
  unsigned count = 0;
  for (char **entry = environ; *entry != NULL; ++entry) {
    if (strcmp(*entry, "LANG=C") != 0 && strcmp(*entry, "LC_ALL=C") != 0)
      return 74;
    ++count;
  }
  if (count != 2)
    return 74;
  sigset_t mask;
  if (sigprocmask(SIG_SETMASK, NULL, &mask) != 0)
    return 75;
  const int signals[] = {SIGINT, SIGHUP, SIGTERM, SIGQUIT, SIGPIPE};
  for (unsigned i = 0; i != sizeof(signals) / sizeof(signals[0]); ++i) {
    struct sigaction action;
    if (sigismember(&mask, signals[i]) != 0 ||
        sigaction(signals[i], NULL, &action) != 0 ||
        action.sa_handler != SIG_DFL)
      return 75;
  }
  atomic_store(&page->header.child_pid, (uint64_t)getpid());
  atomic_store(&page->header.state, 42);
  return munmap(page, FS_DIAG_PAGE_BYTES) == 0 ? 0 : 76;
}

static int mailbox(int variant) {
#ifdef __linux__
  int fd = memfd_create("diagnostic-launcher-fixture",
                        MFD_CLOEXEC | MFD_ALLOW_SEALING);
#else
  // Test-only, one known object per harness invocation, never the production
  // namespace. Only this harness's successful O_EXCL allocation is unlinked.
  char name[32];
  CHECK(snprintf(name, sizeof(name), "/ofdgtest.%ld", (long)getpid()) > 0);
  int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
#endif
  CHECK(fd >= 0);
#ifdef __linux__
  CHECK(fchmod(fd, 0600) == 0);
#endif
  CHECK(ftruncate(fd, variant == 2 ? 0 : FS_DIAG_PAGE_BYTES) == 0);
#ifdef __linux__
  if (variant != 3)
    CHECK(fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL) ==
          0);
#endif
  if (variant == 1) {
#ifdef __linux__
    char path[48];
    CHECK(snprintf(path, sizeof(path), "/proc/self/fd/%d", fd) > 0);
    // Test-only re-open of this exact fresh memfd; never a product parent path.
    int read_only = open(path, O_RDONLY | O_CLOEXEC);
#else
    int read_only = shm_open(name, O_RDONLY, 0);
#endif
    CHECK(read_only >= 0);
    CHECK(close(fd) == 0);
    fd = read_only;
  }
#ifdef __APPLE__
  CHECK(shm_unlink(name) == 0);
#endif
  struct stat metadata;
  CHECK(fstat(fd, &metadata) == 0);
  CHECK(metadata.st_size == (variant == 2 ? 0 : FS_DIAG_PAGE_BYTES));
  CHECK((fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0);
  int owned = fcntl(fd, F_DUPFD_CLOEXEC, 11);
  CHECK(owned >= 11);
  CHECK(close(fd) == 0); // Only our fresh kernel allocation.
  return owned;
}

static int launch(const char *launcher, const char *self, int fd,
                  const char *id, const char *parent_text, int unsafe_stdio,
                  pid_t *child) {
  posix_spawn_file_actions_t actions;
  CHECK(posix_spawn_file_actions_init(&actions) == 0);
  if (fd >= 0)
    CHECK(posix_spawn_file_actions_adddup2(&actions, fd, FS_DIAG_CHILD_FD) ==
          0);
  for (int sink = 0; sink != 3; ++sink) {
    CHECK(posix_spawn_file_actions_addopen(
              &actions, sink, "/dev/null",
              sink == 0 || (unsafe_stdio && sink == 1) ? O_RDONLY : O_WRONLY,
              0) == 0);
  }
  posix_spawnattr_t attributes;
  CHECK(posix_spawnattr_init(&attributes) == 0);
  sigset_t blocked;
  sigemptyset(&blocked);
  const int signals[] = {SIGINT, SIGHUP, SIGTERM, SIGQUIT, SIGPIPE};
  for (unsigned i = 0; i != sizeof(signals) / sizeof(signals[0]); ++i)
    sigaddset(&blocked, signals[i]);
  CHECK(posix_spawnattr_setsigmask(&attributes, &blocked) == 0);
  CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK) == 0);
  char descriptor[16];
  CHECK(snprintf(descriptor, sizeof(descriptor), "%d", probe_fd) > 0);
  char *const argv[] = {(char *)launcher,
                        (char *)id,
                        (char *)parent_text,
                        (char *)self,
                        "--probe",
                        descriptor,
                        NULL};
  char *const env[] = {"UNRELATED_FIXTURE_VALUE=must-not-inherit",
                       "LANG=invalid", "HOME=/not-a-profile", NULL};
  int error = posix_spawn(child, launcher, &actions, &attributes, argv, env);
  CHECK(posix_spawnattr_destroy(&attributes) == 0);
  CHECK(posix_spawn_file_actions_destroy(&actions) == 0);
  if (error)
    return -error;
  int status;
  CHECK(waitpid(*child, &status, 0) == *child);
  CHECK(WIFEXITED(status));
  return WEXITSTATUS(status);
}

static int ordinary_file_mailbox(const fs_diag_page *template) {
  const char *root = getenv("FORESIGHT_TEST_TEMP_ROOT");
  if (root == NULL)
    root = getenv("TMPDIR");
#ifdef __APPLE__
  if (root == NULL)
    root = "/private/var/tmp";
#else
  if (root == NULL)
    root = "/var/tmp";
#endif
  char directory[1024], path[1040];
  int length =
      snprintf(directory, sizeof(directory), "%s/of-launcher-XXXXXX", root);
  CHECK(length > 0 && (size_t)length < sizeof(directory));
  CHECK(mkdtemp(directory) != NULL);
  length = snprintf(path, sizeof(path), "%s/page", directory);
  CHECK(length > 0 && (size_t)length < sizeof(path));
  int fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
  CHECK(fd >= 0 && fchmod(fd, 0600) == 0 &&
        ftruncate(fd, FS_DIAG_PAGE_BYTES) == 0);
  void *page =
      mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  CHECK(page != MAP_FAILED);
  memcpy(page, template, FS_DIAG_PAGE_BYTES);
  CHECK(munmap(page, FS_DIAG_PAGE_BYTES) == 0);
  // All non-type checks match a valid mailbox, including UID, link count, size,
  // mode, flags and initialized identity. Only the kernel-object gate rejects
  // it.
  CHECK(unlink(path) == 0 && rmdir(directory) == 0);
  int owned = fcntl(fd, F_DUPFD_CLOEXEC, 11);
  CHECK(owned >= 11 && close(fd) == 0);
  return owned;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--probe") == 0)
    return probe(atoi(argv[2]));
  CHECK(argc == 3); // Exact launcher and harness paths from the build target.
  alarm(10);
  int fd = mailbox(0);
  fs_diag_page *page =
      mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  CHECK(page != MAP_FAILED);
  memset(page, 0, sizeof(*page));
  page->header.magic = FS_DIAG_PAGE_MAGIC;
  page->header.version = FS_DIAG_PROTOCOL_VERSION;
  page->header.header_bytes = FS_DIAG_HEADER_BYTES;
  page->header.application_pid = (uint64_t)getpid();
  for (unsigned i = 0; i != 32; ++i) {
    char text[3] = {identity[i * 2], identity[i * 2 + 1], 0};
    page->header.native_id[i] = (uint8_t)strtoul(text, NULL, 16);
  }
  char parent[16];
  CHECK(snprintf(parent, sizeof(parent), "%ld", (long)getpid()) > 0);
  struct rlimit original;
  CHECK(getrlimit(RLIMIT_NOFILE, &original) == 0);
  CHECK(original.rlim_max > 64);
  if (original.rlim_max < 5004)
    probe_fd = (int)original.rlim_max - 1;
  if (original.rlim_cur <= (rlim_t)probe_fd) {
    struct rlimit raised = original;
    raised.rlim_cur = (rlim_t)probe_fd + 1;
    CHECK(setrlimit(RLIMIT_NOFILE, &raised) == 0);
  }
  CHECK(dup2(fd, 9) == 9 && dup2(fd, probe_fd) == probe_fd);
  struct rlimit lowered = original;
  lowered.rlim_cur = probe_fd > 512 ? 512 : (rlim_t)probe_fd;
  CHECK(setrlimit(RLIMIT_NOFILE, &lowered) == 0);
  const int signals[] = {SIGINT, SIGHUP, SIGTERM, SIGQUIT, SIGPIPE};
  for (unsigned i = 0; i != sizeof(signals) / sizeof(signals[0]); ++i)
    CHECK(signal(signals[i], SIG_IGN) != SIG_ERR);
  pid_t child;
  CHECK(launch(argv[1], argv[2], fd, identity, parent, 0, &child) == 0);
  CHECK(setrlimit(RLIMIT_NOFILE, &original) == 0);
  CHECK(atomic_load(&page->header.child_pid) == (uint64_t)child);
  CHECK(atomic_load(&page->header.state) == 42);
  CHECK(close(9) == 0 && close(probe_fd) == 0);
  atomic_store(&page->header.state, 0);
  CHECK(
      launch(argv[1], argv[2], fd,
             "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
             parent, 0, &child) == 70);
  CHECK(launch(argv[1], argv[2], fd, identity, "1", 0, &child) == 70);
  CHECK(launch(argv[1], argv[2], fd, identity, parent, 1, &child) == 72);
  CHECK(atomic_load(&page->header.state) == 0);
  page->header.native_id[0] ^= 1;
  CHECK(launch(argv[1], argv[2], fd, identity, parent, 0, &child) == 70);
  CHECK(atomic_load(&page->header.state) == 0);
  page->header.native_id[0] ^= 1;
  CHECK(launch(argv[1], "/__foresight_missing_diagnostic_fixture__", fd,
               identity, parent, 0, &child) == 73);
  CHECK(fcntl(FS_DIAG_CHILD_FD, F_GETFD) == -1);
  CHECK(launch(argv[1], argv[2], -1, identity, parent, 0, &child) == 71);
  int ordinary = ordinary_file_mailbox(page);
  CHECK(launch(argv[1], argv[2], ordinary, identity, parent, 0, &child) == 71);
  CHECK(close(ordinary) == 0);
  for (int variant = 1; variant != 4; ++variant) {
#ifdef __APPLE__
    if (variant == 3)
      continue; // Darwin size is immutable after allocation.
#endif
    int invalid = mailbox(variant);
    int result = launch(argv[1], argv[2], invalid, identity, parent, 0, &child);
    if (result != 71) {
      struct stat metadata;
      CHECK(fstat(invalid, &metadata) == 0);
      fprintf(stderr,
              "invalid mailbox variant %d: exit %d, size %lld, flags %d\n",
              variant, result, (long long)metadata.st_size,
              fcntl(invalid, F_GETFL));
    }
    CHECK(result == 71);
    CHECK(close(invalid) == 0);
  }
  CHECK(munmap(page, FS_DIAG_PAGE_BYTES) == 0 && close(fd) == 0);
  alarm(0);
  puts("diagnostic launcher: same PID, high-FD closure, signals, closed "
       "environment and bootstrap refusal passed");
  return 0;
}
