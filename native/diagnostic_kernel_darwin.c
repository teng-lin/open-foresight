#define _DARWIN_C_SOURCE
#include "diagnostic_kernel.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(__APPLE__) || !defined(__arm64__)
#error Compile the diagnostic kernel backend for the selected product target
#endif
#if defined(FS_DIAG_FIXTURE_BASE) &&                                           \
    (!defined(FS_DIAG_TEST_CONTEXT) || FS_DIAG_TEST_CONTEXT != 1)
#error Private namespace fixtures require an explicitly compiled test context
#endif
#if defined(FS_DIAG_FIXTURE_BASE) != defined(FS_DIAG_FIXTURE_PREFIX)
#error Private namespace fixtures require their own non-product kernel prefix
#endif

#ifdef FS_DIAG_FIXTURE_PREFIX
static const char kernel_prefix[] = FS_DIAG_FIXTURE_PREFIX;
_Static_assert(sizeof(kernel_prefix) >= 3 && sizeof(kernel_prefix) <= 13,
               "bounded private fixture prefix");
#else
static const char kernel_prefix[] = "/ofdg1";
#endif

static int close_owned(int *descriptor) {
  int owned = *descriptor;
  *descriptor = -1;
  return owned < 0 ? 0 : close(owned);
}

static int directory_metadata(int fd, uid_t uid, mode_t mode) {
  struct stat metadata;
  return fstat(fd, &metadata) == 0 && S_ISDIR(metadata.st_mode) &&
         metadata.st_uid == uid && (metadata.st_mode & 07777) == mode &&
         fcntl(fd, F_GETFD) == FD_CLOEXEC;
}

static int supported_mount(int fd) {
  struct statfs mount;
  return fstatfs(fd, &mount) == 0 && (mount.f_flags & MNT_LOCAL) &&
         strncmp(mount.f_fstypename, "apfs", sizeof(mount.f_fstypename)) == 0;
}

static int directory_at(int parent, const char *name) {
  int fd =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return -1;
  if (fd < 11) {
    int high = fcntl(fd, F_DUPFD_CLOEXEC, 11);
    int closed = close(fd);
    if (high < 0 || closed != 0) {
      if (high >= 0)
        close(high);
      return -1;
    }
    fd = high;
  }
  return fd;
}

static int same_directory(int parent, const char *name, int fd) {
  struct stat named, opened;
  return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
         fstat(fd, &opened) == 0 && S_ISDIR(named.st_mode) &&
         named.st_dev == opened.st_dev && named.st_ino == opened.st_ino &&
         named.st_uid == geteuid() && (named.st_mode & 07777) == 0700;
}

static int known_slot(const char *name, size_t length) {
  return length == 3 && name[2] == '\0' && name[0] >= '0' && name[0] <= '6' &&
         name[1] >= '0' && name[1] <= '9' &&
         (name[0] - '0') * 10 + name[1] - '0' < 64;
}

// Public SDK getattrlistbulk only. The fixed buffer and total-entry cap bound
// both a single result and a directory modified concurrently during iteration.
// Names are metadata; no ordinary file candidate is ever data-opened.
static int scan_directory(int fd, int root) {
  struct attrlist requested = {0};
  requested.bitmapcount = ATTR_BIT_MAP_COUNT;
  requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME;
  unsigned entries = 0;
  for (unsigned calls = 0; calls != 67; ++calls) {
    unsigned char buffer[4096];
    int count = getattrlistbulk(fd, &requested, buffer, sizeof(buffer),
                                FSOPT_PACK_INVAL_ATTRS);
    if (count < 0 || count > 66)
      return 0;
    if (count == 0)
      return 1;
    size_t offset = 0;
    for (int index = 0; index != count; ++index) {
      if (++entries > (root ? 66U : 2U) ||
          offset > sizeof(buffer) - sizeof(uint32_t))
        return 0;
      uint32_t length;
      memcpy(&length, buffer + offset, sizeof(length));
      const size_t reference_offset =
          sizeof(uint32_t) + sizeof(attribute_set_t);
      const size_t minimum = reference_offset + sizeof(attrreference_t);
      if (length < minimum || length > sizeof(buffer) - offset)
        return 0;
      attribute_set_t returned;
      attrreference_t reference;
      memcpy(&returned, buffer + offset + sizeof(uint32_t), sizeof(returned));
      memcpy(&reference, buffer + offset + reference_offset, sizeof(reference));
      if ((returned.commonattr & ATTR_CMN_NAME) == 0 ||
          (returned.commonattr & ~(ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME)) !=
              0 ||
          returned.volattr != 0 || returned.dirattr != 0 ||
          returned.fileattr != 0 || returned.forkattr != 0 ||
          reference.attr_dataoffset < (int32_t)sizeof(attrreference_t))
        return 0;
      size_t start = reference_offset + (size_t)reference.attr_dataoffset;
      size_t bytes = reference.attr_length;
      if (start > length || bytes == 0 || bytes > length - start)
        return 0;
      const char *name = (const char *)(buffer + offset + start);
      if (!((bytes == 2 && memcmp(name, ".\0", 2) == 0) ||
            (bytes == 3 && memcmp(name, "..\0", 3) == 0))) {
        if (!root || !known_slot(name, bytes))
          return 0;
        struct stat metadata;
        if (fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(metadata.st_mode) || metadata.st_uid != geteuid() ||
            (metadata.st_mode & 07777) != 0700)
          return 0;
      }
      offset += length;
    }
  }
  return 0;
}

static int private_shm_metadata(int fd, int fresh) {
  struct stat metadata;
  return fstat(fd, &metadata) == 0 && (metadata.st_mode & S_IFMT) == 0 &&
         metadata.st_uid == geteuid() && (metadata.st_mode & 07777) == 0600 &&
         metadata.st_size >= 0 && metadata.st_size <= FS_DIAG_PAGE_BYTES &&
         (!fresh || metadata.st_size == 0) &&
         fcntl(fd, F_GETFD) == FD_CLOEXEC &&
         (fcntl(fd, F_GETFL) & O_ACCMODE) == O_RDWR;
}

int fs_diag_kernel_page_create(fs_diag_kernel_page *result) {
  if (result == NULL)
    return FS_DIAG_KERNEL_UNSUPPORTED;
  *result = (fs_diag_kernel_page){.mapping = NULL, .descriptor = -1};
  int base = -1, root = -1, slot = -1, object = -1;
  int outcome = FS_DIAG_KERNEL_STAGING_UNAVAILABLE;
  int named = 0;
  char root_name[48], slot_name[3], kernel_name[32];
  fs_diag_page *mapping = NULL;
#ifdef FS_DIAG_FIXTURE_BASE
  if (kernel_prefix[0] != '/' || strcmp(kernel_prefix, "/ofdg1") == 0)
    goto done;
  for (size_t i = 1; i != sizeof(kernel_prefix) - 1; ++i) {
    if (!((kernel_prefix[i] >= 'a' && kernel_prefix[i] <= 'z') ||
          (kernel_prefix[i] >= '0' && kernel_prefix[i] <= '9')))
      goto done;
  }
  base = directory_at(AT_FDCWD, FS_DIAG_FIXTURE_BASE);
  if (base < 0 || !directory_metadata(base, geteuid(), 0700))
    goto done;
#else
  base = directory_at(AT_FDCWD, "/private/var/tmp");
  if (base < 0 || !directory_metadata(base, 0, 01777))
    goto done;
#endif
  if (!supported_mount(base)) {
    outcome = FS_DIAG_KERNEL_UNSUPPORTED;
    goto done;
  }
  int length = snprintf(root_name, sizeof(root_name), "of-diag-v1-%lu",
                        (unsigned long)geteuid());
  if (length <= 0 || (size_t)length >= sizeof(root_name))
    goto done;
  if (mkdirat(base, root_name, 0700) != 0 && errno != EEXIST)
    goto done;
  root = directory_at(base, root_name);
  if (root < 0 || !directory_metadata(root, geteuid(), 0700) ||
      !same_directory(base, root_name, root))
    goto done;
  if (!supported_mount(root)) {
    outcome = FS_DIAG_KERNEL_UNSUPPORTED;
    goto done;
  }
  if (!scan_directory(root, 1))
    goto done;
  for (unsigned index = 0; index != 64; ++index) {
    if (snprintf(slot_name, sizeof(slot_name), "%02u", index) != 2)
      goto done;
    if (mkdirat(root, slot_name, 0700) != 0 && errno != EEXIST)
      goto done;
    slot = directory_at(root, slot_name);
    if (slot < 0 || !directory_metadata(slot, geteuid(), 0700) ||
        !same_directory(root, slot_name, slot))
      goto done;
    if (!supported_mount(slot)) {
      outcome = FS_DIAG_KERNEL_UNSUPPORTED;
      goto done;
    }
    // Descriptor validation strictly precedes every flock.
    if (flock(slot, LOCK_EX | LOCK_NB) == 0)
      break;
    int error = errno;
    if (close_owned(&slot) != 0)
      goto done;
    if (error != EWOULDBLOCK && error != EAGAIN) {
      outcome = FS_DIAG_KERNEL_UNSUPPORTED;
      goto done;
    }
  }
  if (slot < 0 || !scan_directory(slot, 0) ||
      !same_directory(base, root_name, root) ||
      !same_directory(root, slot_name, slot))
    goto done;
  length = snprintf(kernel_name, sizeof(kernel_name), "%s.%lu.%s",
                    kernel_prefix, (unsigned long)geteuid(), slot_name);
  if (length <= 0 || (size_t)length >= sizeof(kernel_name))
    goto done;
  object = shm_open(kernel_name, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (object < 0 && errno == EEXIST) {
    // A cooperating creator holds this directory lease until unlink. Inspect
    // only the reserved PSXSHM namespace; foreign/unsafe objects are refused.
    object = shm_open(kernel_name, O_RDWR, 0);
    if (object < 0 || !private_shm_metadata(object, 0))
      goto done;
    if (shm_unlink(kernel_name) != 0 || close_owned(&object) != 0)
      goto done;
    object = shm_open(kernel_name, O_CREAT | O_EXCL | O_RDWR, 0600);
  }
  if (object < 0)
    goto done;
  named = 1;
  if (!private_shm_metadata(object, 1) ||
      ftruncate(object, FS_DIAG_PAGE_BYTES) != 0)
    goto done;
  if (shm_unlink(kernel_name) != 0) {
    // Retain the single staged lease on this failed attempt until process exit.
    // The owning diagnostic context never retries an allocation in this
    // process.
    slot = -1;
    named = 0;
    goto done;
  }
  named = 0;
  if (!same_directory(base, root_name, root) ||
      !same_directory(root, slot_name, slot))
    goto done;
  if (!directory_metadata(slot, geteuid(), 0700) || !supported_mount(slot) ||
      flock(slot, LOCK_UN) != 0 || close_owned(&slot) != 0 ||
      close_owned(&root) != 0 || close_owned(&base) != 0)
    goto done;
  if (object < 11) {
    int high = fcntl(object, F_DUPFD_CLOEXEC, 11);
    int closed = close_owned(&object);
    if (high < 0 || closed != 0) {
      if (high >= 0)
        close(high);
      goto done;
    }
    object = high;
  }
  struct stat metadata;
  if (!private_shm_metadata(object, 0) || fstat(object, &metadata) != 0 ||
      metadata.st_size != FS_DIAG_PAGE_BYTES || metadata.st_nlink != 0)
    goto done;
  mapping = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                 object, 0);
  if (mapping == MAP_FAILED) {
    mapping = NULL;
    outcome = FS_DIAG_KERNEL_UNSUPPORTED;
    goto done;
  }
  if (!fs_diag_page_supported(mapping)) {
    outcome = FS_DIAG_KERNEL_UNSUPPORTED;
    goto done;
  }
  *result = (fs_diag_kernel_page){.mapping = mapping, .descriptor = object};
  mapping = NULL;
  object = -1;
  outcome = FS_DIAG_KERNEL_OK;
done:
  if (named && shm_unlink(kernel_name) != 0)
    slot = -1;
  if (mapping != NULL)
    munmap(mapping, FS_DIAG_PAGE_BYTES);
  close_owned(&object);
  close_owned(&slot);
  close_owned(&root);
  close_owned(&base);
  return outcome;
}
