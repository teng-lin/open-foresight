#define _GNU_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "diagnostic_inherited.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <sys/vfs.h>
#if !defined(__x86_64__)
#error Diagnostic inherited-descriptor gate requires the selected Linux ABI
#endif
#elif defined(__APPLE__) && defined(__arm64__)
#include <libproc.h>
#include <sys/proc_info.h>
_Static_assert(sizeof(struct proc_fdinfo) == 8, "public descriptor-list ABI");
#else
#error Diagnostic inherited-descriptor gate requires a supported product target
#endif

static int mailbox(void) {
  struct stat metadata;
  if (fstat(FS_DIAG_CHILD_FD, &metadata) != 0 || metadata.st_uid != geteuid() ||
      (metadata.st_mode & 07777) != 0600 ||
      metadata.st_size != FS_DIAG_PAGE_BYTES || metadata.st_nlink != 0 ||
      fcntl(FS_DIAG_CHILD_FD, F_GETFD) != 0 ||
      (fcntl(FS_DIAG_CHILD_FD, F_GETFL) & O_ACCMODE) != O_RDWR)
    return 0;
#ifdef __linux__
  return S_ISREG(metadata.st_mode) &&
         fcntl(FS_DIAG_CHILD_FD, F_GET_SEALS) ==
             (F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL);
#else
  return (metadata.st_mode & S_IFMT) == 0;
#endif
}

static int standard_descriptors(void) {
  struct stat expected;
  if (stat("/dev/null", &expected) != 0 || !S_ISCHR(expected.st_mode))
    return FS_DIAG_INHERITED_UNSUPPORTED;
  for (int fd = 0; fd != 3; ++fd) {
    struct stat metadata;
    int flags = fcntl(fd, F_GETFL);
    if (fstat(fd, &metadata) != 0 || !S_ISCHR(metadata.st_mode) ||
        metadata.st_rdev != expected.st_rdev || flags < 0 ||
        (flags & O_ACCMODE) != (fd == 0 ? O_RDONLY : O_WRONLY))
      return FS_DIAG_INHERITED_UNSAFE;
  }
  return FS_DIAG_INHERITED_OK;
}

static int descriptor_safe(int descriptor) {
  if (descriptor < 0)
    return 0;
  if (descriptor < 3)
    return 1; // Exact /dev/null identity/access mode was checked separately.
  int flags = fcntl(descriptor, F_GETFD);
  return flags >= 0 && (flags & FD_CLOEXEC);
}

#ifdef __linux__
static int scan_descriptors(void) {
  int directory =
      open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory < 0)
    return errno == EMFILE || errno == ENFILE ? FS_DIAG_INHERITED_LIMIT
                                              : FS_DIAG_INHERITED_UNSUPPORTED;
  struct statfs filesystem;
  int outcome = FS_DIAG_INHERITED_UNSUPPORTED;
  if (fstatfs(directory, &filesystem) != 0 || filesystem.f_type != 0x9fa0)
    goto done;
  unsigned descriptors = 0;
  for (unsigned calls = 0; calls != 65; ++calls) {
    unsigned char bytes[4096];
    long size = syscall(SYS_getdents64, directory, bytes, sizeof(bytes));
    if (size < 0 || size > (long)sizeof(bytes))
      goto done;
    if (size == 0) {
      outcome = FS_DIAG_INHERITED_OK;
      goto done;
    }
    size_t offset = 0;
    while (offset < (size_t)size) {
      // Linux x86-64 getdents64: inode/off words, u16 reclen, u8 type, name.
      if ((size_t)size - offset < 20)
        goto done;
      uint16_t length;
      memcpy(&length, bytes + offset + 16, sizeof(length));
      if (length < 20 || length > (size_t)size - offset)
        goto done;
      const char *name = (const char *)(bytes + offset + 19);
      const char *end = memchr(name, '\0', length - 19);
      if (end == NULL)
        goto done;
      if (!((end - name == 1 && name[0] == '.') ||
            (end - name == 2 && name[0] == '.' && name[1] == '.'))) {
        if (++descriptors > FS_DIAG_DESCRIPTOR_LIMIT) {
          outcome = FS_DIAG_INHERITED_LIMIT;
          goto done;
        }
        int descriptor = 0;
        if (end == name)
          goto done;
        for (const char *digit = name; digit != end; ++digit) {
          if (*digit < '0' || *digit > '9' ||
              descriptor > (INT_MAX - (*digit - '0')) / 10)
            goto done;
          descriptor = descriptor * 10 + *digit - '0';
        }
        if (!descriptor_safe(descriptor)) {
          outcome = FS_DIAG_INHERITED_UNSAFE;
          goto done;
        }
      }
      offset += length;
    }
  }
  outcome = FS_DIAG_INHERITED_LIMIT;
done:
  if (close(directory) != 0)
    outcome = FS_DIAG_INHERITED_UNSUPPORTED;
  return outcome;
}
#else
static int scan_descriptors(void) {
  struct proc_fdinfo entries[FS_DIAG_DESCRIPTOR_LIMIT];
  _Static_assert(sizeof(entries) == 16384, "fixed descriptor scan workspace");
  int previous = -1;
  for (unsigned pass = 0; pass != 2; ++pass) {
    int size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, entries,
                            (int)sizeof(entries));
    if (size < 0 || size % (int)sizeof(entries[0]) != 0)
      return FS_DIAG_INHERITED_UNSUPPORTED;
    if (size >= (int)sizeof(entries) || (previous >= 0 && size > previous))
      return FS_DIAG_INHERITED_LIMIT;
    if (size == 0)
      return FS_DIAG_INHERITED_UNSUPPORTED;
    for (int index = 0; index != size / (int)sizeof(entries[0]); ++index)
      if (!descriptor_safe(entries[index].proc_fd))
        return FS_DIAG_INHERITED_UNSAFE;
    previous = size;
  }
  return FS_DIAG_INHERITED_OK;
}
#endif

int fs_diag_inherited_page_open(fs_diag_page **result) {
  if (result == NULL)
    return FS_DIAG_INHERITED_UNSAFE;
  *result = NULL;
  // An unknown ordinary candidate is never closed or mutated, even if this
  // private child API was incorrectly reached outside the internal mode.
  if (!mailbox())
    return FS_DIAG_INHERITED_UNSAFE;
  if (fcntl(FS_DIAG_CHILD_FD, F_SETFD, FD_CLOEXEC) != 0)
    return FS_DIAG_INHERITED_UNSUPPORTED;
  int outcome = standard_descriptors();
  if (outcome == FS_DIAG_INHERITED_OK)
    outcome = scan_descriptors();
  fs_diag_page *page = NULL;
  if (outcome == FS_DIAG_INHERITED_OK) {
    page = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                FS_DIAG_CHILD_FD, 0);
    if (page == MAP_FAILED) {
      page = NULL;
      outcome = FS_DIAG_INHERITED_UNSUPPORTED;
    } else if (!fs_diag_page_supported(page)) {
      outcome = FS_DIAG_INHERITED_UNSUPPORTED;
    }
  }
  if (close(FS_DIAG_CHILD_FD) != 0)
    outcome = FS_DIAG_INHERITED_UNSUPPORTED;
  if (outcome != FS_DIAG_INHERITED_OK) {
    if (page != NULL)
      munmap(page, FS_DIAG_PAGE_BYTES);
    return outcome;
  }
  *result = page;
  return FS_DIAG_INHERITED_OK;
}
