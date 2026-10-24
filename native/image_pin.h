#pragma once
#include <cstddef>
#include <cstdint>
#include <dlfcn.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <link.h>
#endif

namespace foresight {
// Retain an already mapped image, never load replacement code by pathname.
// The caller caches this result once per image; this helper has no static/TLS
// state so the same implementation can be tested in an unloadable fixture.
inline bool retain_native_image(const void *anchor,
                                const char *exported_symbol) noexcept {
  Dl_info own{};
  if (!dladdr(anchor, &own) || !own.dli_fname)
    return false;
#ifdef __APPLE__
  if (own.dli_fbase == _dyld_get_image_header(0))
    return true;
#else
  struct MainImage {
    const void *address;
    bool found = false;
  } main{anchor};
  dl_iterate_phdr(
      [](dl_phdr_info *info, size_t, void *context) {
        auto &image = *static_cast<MainImage *>(context);
        if (info->dlpi_name && *info->dlpi_name)
          return 0;
        const auto address = reinterpret_cast<uintptr_t>(image.address);
        for (size_t n = 0; n < info->dlpi_phnum; ++n) {
          const auto &segment = info->dlpi_phdr[n];
          if (segment.p_type == PT_LOAD &&
              address >= info->dlpi_addr + segment.p_vaddr &&
              address < info->dlpi_addr + segment.p_vaddr + segment.p_memsz) {
            image.found = true;
            return 1;
          }
        }
        return 0;
      },
      &main);
  if (main.found)
    return true;
#endif
  void *mapping = dlopen(own.dli_fname, RTLD_NOW | RTLD_NOLOAD);
  if (!mapping)
    return false;
  Dl_info resolved{};
  void *symbol = dlsym(mapping, exported_symbol);
  if (!symbol || !dladdr(symbol, &resolved) ||
      resolved.dli_fbase != own.dli_fbase) {
    dlclose(mapping);
    return false;
  }
  // One intentional reference belongs to this process, independent of callers.
  return true;
}
} // namespace foresight
