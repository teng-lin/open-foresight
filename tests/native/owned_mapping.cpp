#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <iostream>
#include <spawn.h>
#include <stdexcept>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
extern char **environ;
namespace fs = std::filesystem;
void require(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
template <class T> T symbol(void *mapping, const char *name) {
  auto value = reinterpret_cast<T>(dlsym(mapping, name));
  require(value, "complete mapping capability required");
  return value;
}
struct Scratch {
  fs::path path;
  Scratch() {
    const char *root = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
#ifdef __APPLE__
    if (!root)
      root = "/private/var/tmp";
#else
    if (!root)
      root = "/var/tmp";
#endif
    auto pattern = (fs::canonical(root) / "owned-map-XXXXXX").string();
    require(mkdtemp(pattern.data()) != nullptr, "private mapping fixture root");
    path = pattern;
  }
  ~Scratch() {
    std::error_code ignored;
    fs::remove_all(path, ignored);
  }
};
void same_image(const void *address, const void *base) {
  Dl_info info{};
  require(dladdr(address, &info) && info.dli_fbase == base,
          "retained symbol must belong to original mapped image");
}
// This module has no Objective-C, TLS, C++ singleton or GNU-unique data. Its
// unload control must pass before it can prove the shared pin helper works.
int pin_fixture(const char *library, const char *replacement, bool omitted) {
  Scratch scratch;
  auto control = scratch.path / "unowned.so";
  fs::copy_file(library, control);
  void *mapping = dlopen(control.c_str(), RTLD_NOW | RTLD_LOCAL);
  require(mapping, "unload control fixture loaded");
  require(symbol<int (*)()>(mapping, "fs_pin_fixture_identity")() == 1,
          "unowned control marker");
  require(dlclose(mapping) == 0, "unowned control reference released");
  void *remaining = dlopen(control.c_str(), RTLD_NOW | RTLD_NOLOAD);
  if (remaining)
    dlclose(remaining);
  require(!remaining, "control fixture must actually unload without a pin");

  auto path = scratch.path / "owned.so";
  auto parked = scratch.path / "owned.original.so";
  fs::copy_file(library, path);
  mapping = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  require(mapping, "pin fixture loaded");
  auto identity = symbol<int (*)()>(mapping, "fs_pin_fixture_identity");
  auto retain = symbol<bool (*)()>(mapping, "fs_pin_fixture_retain");
  Dl_info original{};
  require(dladdr(reinterpret_cast<void *>(identity), &original),
          "original fixture image observed");
  fs::rename(path, parked);
  fs::copy_file(replacement, path);
  require(retain(), "same shared helper retained original image");
  require(dlclose(mapping) == 0, "caller reference released");
  remaining = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);
  if (omitted) {
    if (remaining)
      dlclose(remaining);
    require(!remaining, "pin-omission control unexpectedly retained its image");
    // This exact result proves unloading was detected before any stale call.
    return 86;
  }
  require(remaining, "original image must remain mapped after caller release");
  auto kept = symbol<int (*)()>(remaining, "fs_pin_fixture_identity");
  same_image(reinterpret_cast<void *>(kept), original.dli_fbase);
  require(kept() == 1, "replacement must not supply original code");
  fs::path distinct = scratch.path / "replacement.so";
  fs::copy_file(replacement, distinct);
  void *other = dlopen(distinct.c_str(), RTLD_NOW | RTLD_LOCAL);
  require(other, "replacement is a valid independently loadable image");
  auto other_identity = symbol<int (*)()>(other, "fs_pin_fixture_identity");
  Dl_info other_info{};
  require(dladdr(reinterpret_cast<void *>(other_identity), &other_info) &&
              other_info.dli_fbase != original.dli_fbase &&
              other_identity() == 2,
          "valid replacement has different bytes and image identity");
  require(dlclose(other) == 0 && dlclose(remaining) == 0,
          "temporary observation references released");
  return 0;
}
void native_unowned(const char *library) {
  Scratch scratch;
  auto control = scratch.path / "native-control.dylib";
  fs::copy_file(library, control);
  void *mapping = dlopen(control.c_str(), RTLD_NOW | RTLD_LOCAL);
  require(mapping, "actual native unload observation loaded");
  require(symbol<int (*)()>(mapping, "fs_abi_version")() == 1,
          "base ABI checked before dependent symbols");
  require(dlclose(mapping) == 0, "actual unowned caller reference released");
  void *intrinsic = dlopen(control.c_str(), RTLD_NOW | RTLD_NOLOAD);
  std::cout << "native_unowned_intrinsic_retention=" << bool(intrinsic) << '\n';
  if (intrinsic)
    dlclose(intrinsic);
  // This observation is not attributed to the explicit pin: platform loaders
  // may retain GNU-unique, Objective-C or TLS images even without an owner.
}
void actual_mapping(const char *library, const char *runner) {
  Scratch scratch;
  auto path = scratch.path / "native-owned.dylib";
  auto parked = scratch.path / "native-owned.original.dylib";
  fs::copy_file(library, path);
  void *mapping = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  require(mapping, "actual private native mapping loaded");
  auto abi = symbol<int (*)()>(mapping, "fs_abi_version");
  require(abi() == 1, "base ABI checked before dependent symbols");
  auto lifetime = symbol<int (*)()>(mapping, "fs_lifetime_version");
  require(lifetime() == 2, "owned v2 capability checked");
  Dl_info original{};
  require(dladdr(reinterpret_cast<void *>(lifetime), &original) &&
              original.dli_fname && fs::equivalent(original.dli_fname, path),
          "actual image must be the selected original private file");
  auto create = symbol<uint64_t (*)(const char *, const char *, int, int)>(
      mapping, "fs_owned_engine_create");
  auto retire = symbol<uint64_t (*)(uint64_t)>(mapping, "fs_engine_retire");
  auto status = symbol<int (*)(uint64_t)>(mapping, "fs_operation_status");
  auto release = symbol<int (*)(uint64_t)>(mapping, "fs_owner_release");
  // Replace before first owned admission, so the pin cannot simply rely on an
  // unchanged pathname. The replacement is a valid DSO, never a text sentinel.
  fs::rename(path, parked);
  fs::copy_file(library, path);
  const auto owner = create(runner, "/dev/null", 0, 0);
  require(owner, "owned admission retains original actual mapping");
  require(dlclose(mapping) == 0, "caller native reference released");
  void *kept = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);
  require(kept, "actual original mapping still observable");
  same_image(dlsym(kept, "fs_lifetime_version"), original.dli_fbase);
  require(dlclose(kept) == 0, "actual observation reference released");
  const auto token = retire(owner);
  require(token, "retirement uses original mapping after valid replacement");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (status(token) == 0 && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  require(status(token) == 1 && release(owner) == 0,
          "actual destruction and acknowledgement use original retained image");
}
int main(int argc, char **argv) {
  try {
    if (argc == 4 && std::string(argv[1]) == "--omitted")
      return pin_fixture(argv[2], argv[3], true);
    if (argc == 3 && std::string(argv[1]) == "--native-unowned") {
      native_unowned(argv[2]);
      return 0;
    }
    if (argc != 5)
      return 2;
    require(pin_fixture(argv[2], argv[3], false) == 0,
            "shared helper positive case");
    pid_t child = -1;
    char *command[]{argv[0], const_cast<char *>("--omitted"), argv[4], argv[3],
                    nullptr};
    require(posix_spawn(&child, argv[0], nullptr, nullptr, command, environ) ==
                0,
            "pin-omission control started");
    int status = 0;
    require(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
                WEXITSTATUS(status) == 86,
            "omitting pin must expose actual unloading, not arbitrary failure");
    // Observe intrinsic retention in a separate process: an unowned image
    // retained by dyld must not satisfy the later owned-image path control.
    char *unowned[]{argv[0], const_cast<char *>("--native-unowned"), argv[1],
                    nullptr};
    require(posix_spawn(&child, argv[0], nullptr, nullptr, unowned, environ) ==
                0,
            "unowned native observation started");
    require(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
                WEXITSTATUS(status) == 0,
            "unowned native observation completed normally");
    actual_mapping(argv[1], argv[0]);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
