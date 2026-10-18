#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <unistd.h>

// The linked production library supplies every other native entry point. Only
// this test's polling is held back, while its real capture worker fills the
// queue.
extern "C" char *fs_event_poll(void *handle, int timeout) {
  const char *gate = std::getenv("FORESIGHT_TEST_CAPTURE_POLL_GATE");
  const char *ready = std::getenv("FORESIGHT_TEST_CAPTURE_READY");
  if (gate && ready && access(gate, F_OK) == 0 && access(ready, F_OK) != 0)
    return nullptr;
  using Poll = char *(*)(void *, int);
  static const Poll poll = [] {
    void *library = dlopen(std::getenv("FORESIGHT_TEST_REAL_NATIVE"), RTLD_NOW);
    if (!library) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    auto function = reinterpret_cast<Poll>(dlsym(library, "fs_event_poll"));
    if (!function) {
      std::fputs(dlerror(), stderr);
      std::abort();
    }
    return function;
  }();
  return poll(handle, timeout);
}
