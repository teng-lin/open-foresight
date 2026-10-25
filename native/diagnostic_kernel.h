#ifndef FORESIGHT_DIAGNOSTIC_KERNEL_H
#define FORESIGHT_DIAGNOSTIC_KERNEL_H

#include "diagnostic_protocol.h"

// Private support-library implementation. No caller-provided descriptor or path
// can enter the parent allocation boundary. Successful allocation is always a
// fresh kernel object, already unlinked, fixed-size and atomically CLOEXEC.
typedef struct fs_diag_kernel_page {
  fs_diag_page *mapping;
  int descriptor;
} fs_diag_kernel_page;

enum {
  FS_DIAG_KERNEL_OK = 0,
  FS_DIAG_KERNEL_UNSUPPORTED = 1,
  FS_DIAG_KERNEL_STAGING_UNAVAILABLE = 2
};

int fs_diag_kernel_page_create(fs_diag_kernel_page *result);

#endif
