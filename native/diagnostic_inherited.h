#ifndef FORESIGHT_DIAGNOSTIC_INHERITED_H
#define FORESIGHT_DIAGNOSTIC_INHERITED_H

#include "diagnostic_protocol.h"

enum {
  FS_DIAG_INHERITED_OK = 0,
  FS_DIAG_INHERITED_UNSUPPORTED = 1,
  FS_DIAG_INHERITED_LIMIT = 2,
  FS_DIAG_INHERITED_UNSAFE = 3,
  FS_DIAG_DESCRIPTOR_LIMIT = 2048
};

// Private exec-child startup only, before profile/application authority. No
// descriptor/path argument can select an ordinary candidate. Validate the fixed
// kernel mailbox, remove its one inherited CLOEXEC exception, reject any other
// non-CLOEXEC descriptor, map it and close its known kernel FD. The native
// child context owns the returned mapping; identity/authentication is still
// required. Never invoke this function as a parent-process logging allocation
// API.
#ifdef __cplusplus
extern "C" {
#endif
int fs_diag_inherited_page_open(fs_diag_page **result);
#ifdef __cplusplus
}
#endif

#endif
