#pragma once
#include "../../native/portable_process.h"
#include "c/conversation.h"
#include "c/embedding_engine.h"
#include "c/engine.h"
#include "c/error_reporter.h"
#include "c/foresight_extensions.h"
#include <array>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/evp.h>
#endif
#include <stdexcept>
#include <string>
#include <unordered_map>

// The runtime is loaded locally, never downloaded by the application. Keep it
// resident until process exit: its background/global state outlives engines.
class LiteRt {
  void *library_;
  mutable std::mutex symbols_mutex_;
  mutable std::unordered_map<std::string, void *> symbols_;

  static std::string digest(const std::filesystem::path &path) {
    std::ifstream input(path, std::ios::binary);
    if (!input)
      throw std::runtime_error(
          "Cannot load native LiteRT-LM 0.18.0: library is unavailable: " +
          path.string());
#ifdef __APPLE__
    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1)
      throw std::runtime_error("Cannot initialize LiteRT-LM checksum");
#else
    auto context = std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)>(
        EVP_MD_CTX_new(), EVP_MD_CTX_free);
    if (!context ||
        EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1)
      throw std::runtime_error("Cannot initialize LiteRT-LM checksum");
#endif
    std::array<char, 65536> buffer;
    while (input) {
      input.read(buffer.data(), buffer.size());
#ifdef __APPLE__
      if (CC_SHA256_Update(&context, buffer.data(),
                           static_cast<CC_LONG>(input.gcount())) != 1)
#else
      if (EVP_DigestUpdate(context.get(), buffer.data(), input.gcount()) != 1)
#endif
        throw std::runtime_error("Cannot hash LiteRT-LM library");
    }
    if (!input.eof())
      throw std::runtime_error("Cannot read LiteRT-LM library");
#ifdef __APPLE__
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    unsigned int size = CC_SHA256_DIGEST_LENGTH;
    if (CC_SHA256_Final(bytes, &context) != 1)
#else
    unsigned char bytes[EVP_MAX_MD_SIZE];
    unsigned int size = 0;
    if (EVP_DigestFinal_ex(context.get(), bytes, &size) != 1)
#endif
      throw std::runtime_error("Cannot finish LiteRT-LM checksum");
    const char *hex = "0123456789abcdef";
    std::string result;
    for (unsigned int i = 0; i < size; ++i) {
      result += hex[bytes[i] >> 4];
      result += hex[bytes[i] & 15];
    }
    return result;
  }
  static std::string expected_digest(const std::filesystem::path &path) {
    // Release metadata is anchored to this executable, so an environment
    // override cannot redirect the identity check to its own manifest.
    const auto directory = foresight::executable_path().parent_path();
    // App bundle Contents admits code directories; runtime metadata belongs in
    // Resources so codesign seals it as data. Resource-bin and Linux hosts
    // retain the sibling manifest layout.
    const auto manifest =
        directory.filename() == "MacOS" &&
                directory.parent_path().filename() == "Contents"
            ? directory.parent_path() / "Resources/manifest.json"
            : directory / "../manifest.json";
    if (std::filesystem::is_regular_file(manifest)) {
      std::ifstream input(manifest);
      auto runtime = nlohmann::json::parse(input).at("gemma_runtime");
      if (runtime.at("version") != "0.18.0")
        throw std::runtime_error("Unsupported bundled LiteRT-LM version");
      return runtime.at("sha256").get<std::string>();
    }
    // Source-built developer runners use the verified build output next to
    // their selected library. Unmodified release builds use the upstream pin.
    const auto identity = path.parent_path() / "litert-identity.json";
    const auto build_manifest =
        std::filesystem::is_regular_file(identity)
            ? identity
            : path.parent_path() / "build-manifest.json";
    if (std::filesystem::is_regular_file(build_manifest)) {
      std::ifstream input(build_manifest);
      auto build = nlohmann::json::parse(input);
      if (build.at("version") != "0.18.0" ||
          build.at("upstream_commit") !=
              "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27")
        throw std::runtime_error("Unsupported source-built LiteRT-LM version");
      return build.at("library_sha256").get<std::string>();
    }
    return "193a2d8581ff525a242334863f36b439e4ba8bd08f31a33d87c503be4fb61cff";
  }
  void *lookup(const char *name) const {
    std::lock_guard lock(symbols_mutex_);
    const auto found = symbols_.find(name);
    if (found != symbols_.end())
      return found->second;
    auto pointer = dlsym(library_, name);
    symbols_.emplace(name, pointer);
    return pointer;
  }

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
    if (digest(path) != expected_digest(path))
      throw std::runtime_error("LiteRT-LM 0.18.0 library checksum mismatch");
    library_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library_)
      throw std::runtime_error("Cannot load native LiteRT-LM 0.18.0: " +
                               std::string(dlerror()));
  }
  bool supports_native_stop_tokens() const {
    return lookup("litert_lm_session_config_add_stop_token_sequence") !=
           nullptr;
  }
  template <class T> T symbol(const char *name) const {
    auto ptr = lookup(name);
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
