#pragma once
#include "../../native/portable_process.h"
#include "c/conversation.h"
#include "c/embedding_engine.h"
#include "c/engine.h"
#include "c/error_reporter.h"
#include "c/foresight_extensions.h"
#include <dlfcn.h>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>

// The runtime is loaded locally, never downloaded by the application. Keep it
// resident until process exit: its background/global state outlives engines.
class LiteRt {
  void *library_;

public:
  LiteRt() {
#ifdef __APPLE__
    constexpr const char *library_name = "liblitert-lm.dylib";
#else
    constexpr const char *library_name = "liblitert-lm.so";
#endif
    const char *configured = std::getenv("FORESIGHT_LITERT_LIBRARY");
    auto path = configured ? std::filesystem::path(configured)
                           : (foresight::executable_path().parent_path() /
                              ("../lib/" + std::string(library_name)))
                                 .lexically_normal();
    if (!configured && !std::filesystem::is_regular_file(path))
      path = (foresight::executable_path().parent_path() /
              ("../../lib/" + std::string(library_name)))
                 .lexically_normal();
    library_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library_)
      throw std::runtime_error("Cannot load native LiteRT-LM 0.18.0: " +
                               std::string(dlerror()));
  }
  bool supports_native_stop_tokens() const {
    return dlsym(library_,
                 "litert_lm_session_config_add_stop_token_sequence") != nullptr;
  }
  template <class T> T symbol(const char *name) const {
    auto ptr = dlsym(library_, name);
    if (!ptr)
      throw std::runtime_error(std::string("Missing LiteRT-LM 0.18.0 API: ") +
                               name);
    return reinterpret_cast<T>(ptr);
  }
};
#define LM(name) lm.symbol<decltype(&litert_lm_##name)>("litert_lm_" #name)
template <class T, class F> auto handle(T *p, F destroy) {
  if (!p)
    throw std::runtime_error("Native LiteRT operation failed");
  return std::unique_ptr<T, F>(p, destroy);
}
