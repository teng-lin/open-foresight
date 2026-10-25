#define _GNU_SOURCE
#include "diagnostic_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#elif !defined(__APPLE__)
#error Unsupported diagnostic launcher target
#endif

#ifndef FORESIGHT_DIAGNOSTIC_NATIVE_ID
#error Build tooling must supply the diagnostic native input identity
#endif

static const char native_id[] = FORESIGHT_DIAGNOSTIC_NATIVE_ID;
_Static_assert(sizeof(native_id) == 65, "native identity must have 64 digits");

static int digit(unsigned char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  return -1;
}

static int parent_pid(const char *text, pid_t *pid) {
  size_t count = strnlen(text, 11);
  if (count == 0 || count > 10 || text[0] == '0')
    return 0;
  uint64_t value = 0;
  for (size_t i = 0; i != count; ++i) {
    if (text[i] < '0' || text[i] > '9')
      return 0;
    value = value * 10 + (unsigned)(text[i] - '0');
    if (value > INT_MAX)
      return 0;
  }
  *pid = (pid_t)value;
  return value > 1;
}

static int validate_mailbox(void) {
  struct stat status;
  if (fstat(FS_DIAG_CHILD_FD, &status) != 0 || status.st_uid != geteuid() ||
      (status.st_mode & 07777) != 0600 ||
      status.st_size != FS_DIAG_PAGE_BYTES ||
      fcntl(FS_DIAG_CHILD_FD, F_GETFD) != 0 ||
      (fcntl(FS_DIAG_CHILD_FD, F_GETFL) & O_ACCMODE) != O_RDWR)
    return 71;
#ifdef __linux__
  const int seals = F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL;
  if (!S_ISREG(status.st_mode) || status.st_nlink != 0 ||
      fcntl(FS_DIAG_CHILD_FD, F_GET_SEALS) != seals)
    return 71;
#else
  // XNU PSXSHM objects deliberately have no vnode file-type bits. A VNODE or
  // arbitrary inherited regular file cannot pass this kernel-object gate.
  if ((status.st_mode & S_IFMT) != 0 || status.st_nlink != 0)
    return 71;
#endif
  fs_diag_page *page = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ, MAP_SHARED,
                            FS_DIAG_CHILD_FD, 0);
  if (page == MAP_FAILED)
    return 71;
  int valid = fs_diag_page_supported(page) &&
              page->header.magic == FS_DIAG_PAGE_MAGIC &&
              page->header.version == FS_DIAG_PROTOCOL_VERSION &&
              page->header.header_bytes == FS_DIAG_HEADER_BYTES &&
              page->header.application_pid == (uint64_t)getppid();
  for (unsigned i = 0; i != 32; ++i) {
    int hi = digit((unsigned char)native_id[i * 2]);
    int lo = digit((unsigned char)native_id[i * 2 + 1]);
    if (hi < 0 || lo < 0 ||
        page->header.native_id[i] != (uint8_t)(hi * 16 + lo))
      valid = 0;
  }
  if (munmap(page, FS_DIAG_PAGE_BYTES) != 0)
    return 71;
  return valid ? 0 : 70;
}

static int validate_stdio(void) {
  struct stat expected;
  if (stat("/dev/null", &expected) != 0 || !S_ISCHR(expected.st_mode))
    return 0;
  for (int fd = 0; fd != 3; ++fd) {
    struct stat status;
    int flags = fcntl(fd, F_GETFL);
    if (fstat(fd, &status) != 0 || !S_ISCHR(status.st_mode) ||
        status.st_rdev != expected.st_rdev || flags < 0 ||
        (flags & O_ACCMODE) != (fd == 0 ? O_RDONLY : O_WRONLY))
      return 0;
  }
  return 1;
}

int main(int argc, char **argv) {
  // No failure text: callers observe only the fixed bootstrap exit status.
  if (argc < 4 || argc > 16)
    return 70;
  size_t total = 0;
  for (int i = 0; i != argc; ++i) {
    size_t length = strnlen(argv[i], 1025);
    if (length == 0 || length > 1024 || total + length + 1 > 2048)
      return 70;
    total += length + 1;
  }
  pid_t parent;
  if (strcmp(argv[1], native_id) != 0 || !parent_pid(argv[2], &parent) ||
      getppid() != parent || argv[3][0] != '/')
    return 70;
  if (!validate_stdio())
    return 72;
  int mailbox_error = validate_mailbox();
  if (mailbox_error)
    return mailbox_error;
  sigset_t empty;
  sigemptyset(&empty);
  const int signals[] = {SIGINT, SIGHUP, SIGTERM, SIGQUIT, SIGPIPE};
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0 || setpgid(0, 0) != 0)
    return 72;
  for (unsigned i = 0; i != sizeof(signals) / sizeof(signals[0]); ++i)
    if (sigaction(signals[i], &action, NULL) != 0)
      return 72;
  if (getppid() != parent)
    return 70;
  char *const environment[] = {"LANG=C", "LC_ALL=C", NULL};
#ifdef __linux__
#if !defined(__x86_64__)
#error Linux diagnostic launcher supports the packaged x86-64 ABI only
#endif
  // Raw close_range avoids adding a glibc symbol requirement. Failure refuses
  // this diagnostic child; no RLIMIT enumeration or partial-close fallback.
  if (syscall(436, 3U, 9U, 0U) != 0 || syscall(436, 11U, UINT_MAX, 0U) != 0)
    return 71;
  execve(argv[3], argv + 3, environment);
  return 73;
#else
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  if (posix_spawn_file_actions_init(&actions) != 0)
    return 71;
  if (posix_spawnattr_init(&attributes) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    return 72;
  }
  int error = 0;
  const int inherited[] = {0, 1, 2, FS_DIAG_CHILD_FD};
  for (unsigned i = 0; i != sizeof(inherited) / sizeof(inherited[0]); ++i)
    if (posix_spawn_file_actions_addinherit_np(&actions, inherited[i]) != 0)
      error = 1;
  if (posix_spawnattr_setflags(
          &attributes, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT) != 0)
    error = 1;
  pid_t unused;
  if (!error)
    (void)posix_spawn(&unused, argv[3], &actions, &attributes, argv + 3,
                      environment);
  // Successful SETEXEC never returns. Both cleanup functions are local only.
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  return error ? 71 : 73;
#endif
}
