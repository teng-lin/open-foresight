#define _GNU_SOURCE
#include "diagnostic_kernel.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(__linux__) || !defined(__x86_64__)
#error Compile the diagnostic kernel backend for the selected product target
#endif

int fs_diag_kernel_page_create(fs_diag_kernel_page *result) {
  if (result == NULL)
    return FS_DIAG_KERNEL_UNSUPPORTED;
  *result = (fs_diag_kernel_page){.mapping = NULL, .descriptor = -1};
  int descriptor =
      memfd_create("foresight-diagnostic", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  if (descriptor < 0)
    return FS_DIAG_KERNEL_UNSUPPORTED;
  // Relocation and closes concern only this internally allocated kernel object;
  // no ordinary file candidate can reach either operation.
  if (descriptor < 11) {
    int high = fcntl(descriptor, F_DUPFD_CLOEXEC, 11);
    int closed = close(descriptor);
    if (high < 0 || closed != 0) {
      if (high >= 0)
        close(high);
      return FS_DIAG_KERNEL_UNSUPPORTED;
    }
    descriptor = high;
  }
  const int seals = F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL;
  struct stat metadata;
  if (fchmod(descriptor, 0600) != 0 ||
      ftruncate(descriptor, FS_DIAG_PAGE_BYTES) != 0 ||
      fcntl(descriptor, F_ADD_SEALS, seals) != 0 ||
      fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      metadata.st_uid != geteuid() || metadata.st_nlink != 0 ||
      (metadata.st_mode & 07777) != 0600 ||
      metadata.st_size != FS_DIAG_PAGE_BYTES ||
      fcntl(descriptor, F_GETFD) != FD_CLOEXEC ||
      (fcntl(descriptor, F_GETFL) & O_ACCMODE) != O_RDWR ||
      fcntl(descriptor, F_GET_SEALS) != seals) {
    close(descriptor);
    return FS_DIAG_KERNEL_UNSUPPORTED;
  }
  fs_diag_page *mapping = mmap(NULL, FS_DIAG_PAGE_BYTES, PROT_READ | PROT_WRITE,
                               MAP_SHARED, descriptor, 0);
  if (mapping == MAP_FAILED) {
    close(descriptor);
    return FS_DIAG_KERNEL_UNSUPPORTED;
  }
  if (!fs_diag_page_supported(mapping)) {
    munmap(mapping, FS_DIAG_PAGE_BYTES);
    close(descriptor);
    return FS_DIAG_KERNEL_UNSUPPORTED;
  }
  *result = (fs_diag_kernel_page){.mapping = mapping, .descriptor = descriptor};
  return FS_DIAG_KERNEL_OK;
}
