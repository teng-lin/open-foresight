#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <unistd.h>
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
template <class T> T symbol(void *mapping, const char *name) {
  auto value = reinterpret_cast<T>(dlsym(mapping, name));
  require(value, "complete mapping capability required");
  return value;
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  const char *scratch = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
  if (!scratch)
    return 3;
  auto path = std::filesystem::path(scratch) /
              ("owned-mapping-" + std::to_string(getpid()) + ".dylib");
  auto parked = path.string() + ".original";
  try {
    std::filesystem::copy_file(argv[1], path);
    void *mapping = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    require(mapping, "actual private native mapping loaded");
    auto abi = symbol<int (*)()>(mapping, "fs_abi_version");
    require(abi() == 1, "base ABI checked before dependent symbols");
    auto lifetime = symbol<int (*)()>(mapping, "fs_lifetime_version");
    require(lifetime() == 2, "owned v2 capability checked");
    auto create = symbol<uint64_t (*)(const char *, const char *, int, int)>(
        mapping, "fs_owned_engine_create");
    auto retire = symbol<uint64_t (*)(uint64_t)>(mapping, "fs_engine_retire");
    auto status = symbol<int (*)(uint64_t)>(mapping, "fs_operation_status");
    auto release = symbol<int (*)(uint64_t)>(mapping, "fs_owner_release");
    auto owner = create(argv[0], "/dev/null", 0, 0);
    require(owner, "owned admission pins exact actual mapping");
    std::filesystem::rename(path, parked);
    std::ofstream(path) << "Replacement pathname is not a native library\n";
    require(dlclose(mapping) == 0, "caller library reference released");
    // Only the native exact-image pin keeps these real code addresses valid.
    // Reopening the replaced pathname cannot create a valid replacement owner.
    const auto token = retire(owner);
    require(token,
            "retirement uses original mapping after pathname replacement");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (status(token) == 0 && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    require(status(token) == 1 && release(owner) == 0,
            "actual destruction and acknowledgement use original pinned bytes");
    std::filesystem::remove(path);
    std::filesystem::remove(parked);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    std::filesystem::remove(parked, ignored);
    return 1;
  }
}
