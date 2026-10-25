#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

// Test-only crash gate after a real payload unlink. It does not simulate
// successful cleanup or change the application/storage implementation.
extern "C" int diagnostic_cleanup_unlinkat(int directory, const char *name,
                                           int flags) {
#ifdef __APPLE__
  // dyld keeps the interposing image's own import bound to the original.
  // Looking it up with RTLD_NEXT is interposed again and recurses on Darwin.
  const int status = unlinkat(directory, name, flags);
#else
  using Unlink = int (*)(int, const char *, int);
  static const auto real_unlink =
      reinterpret_cast<Unlink>(dlsym(RTLD_NEXT, "unlinkat"));
  if (!real_unlink)
    _exit(72);
  const int status = real_unlink(directory, name, flags);
#endif
  if (status == 0 && std::getenv("FORESIGHT_CLEANUP_CRASH_GATE") &&
      std::strcmp(name, "0.jsonl") == 0) {
    constexpr char ready[] = "cleanup-stopped\n";
    if (write(STDOUT_FILENO, ready, sizeof(ready) - 1) !=
        static_cast<ssize_t>(sizeof(ready) - 1))
      _exit(71);
    raise(SIGSTOP);
  }
  return status;
}
#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement;
  const void *replacee;
} cleanup_interpose = {
    reinterpret_cast<const void *>(diagnostic_cleanup_unlinkat),
    reinterpret_cast<const void *>(unlinkat)};
#else
extern "C" int unlinkat(int directory, const char *name, int flags) {
  return diagnostic_cleanup_unlinkat(directory, name, flags);
}
#endif
