#define _POSIX_C_SOURCE 200809L
#include "diagnostic_protocol.h"
#include "diagnostic_support.h"

#include <stdint.h>
#include <time.h>

// Linked only into the private Dart-watch fixture support image. Publishing the
// reply from inside this call proves the main isolate entered this same FFI
// invocation before the parent initiates FORCE. The call deliberately cannot
// return normally within either the FORCE or active-operation deadline test.
int fs_diag_fixture_held_result(uint64_t id) {
  if (fs_diag_child_operation(id, 1) != 0 ||
      fs_diag_support_send(id, FS_DIAG_RESULT, 1, 4, (const uint8_t *)"test",
                           4) != FS_DIAG_CHANNEL_COMPLETE)
    return -1;
  struct timespec remaining = {30, 0};
  while (nanosleep(&remaining, &remaining) != 0) {
  }
  return 99;
}
