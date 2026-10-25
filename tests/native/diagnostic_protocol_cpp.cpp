#include "diagnostic_protocol.h"

static_assert(alignof(fs_diag_atomic64) == 8);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

extern "C" int fs_diag_cpp_header_contract(void) {
  return sizeof(fs_diag_page) == FS_DIAG_PAGE_BYTES;
}
