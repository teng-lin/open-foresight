// Compile-only preparation is safe: original code is reached only in --run.
// ABI evidence: ida/oracle-textcache-{generate-cabi,close-cabi,destroy-cabi}.json.
#include <CommonCrypto/CommonDigest.h>
#include <Metal/Metal.h>
#include <arpa/inet.h>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
namespace fs = std::filesystem;
struct Options {
  const char *model;
  int32_t model_type;
  int32_t padding;
  const char *lora;
  int32_t rank;
  float temperature;
  int32_t top_k, max_tokens;
  const char *system, *context_template, *user_template;
};
struct Input { const char *context, *user; };
static_assert(sizeof(Options) == 64 && sizeof(Input) == 16);
static_assert(offsetof(Options, model_type) == 8 && offsetof(Options, lora) == 16);
static_assert(offsetof(Options, temperature) == 28 && offsetof(Options, top_k) == 32);
static_assert(offsetof(Options, max_tokens) == 36 && offsetof(Options, system) == 40);
static_assert(offsetof(Options, context_template) == 48 && offsetof(Options, user_template) == 56);
constexpr const char *model_digest = "889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f";
std::string digest(const fs::path &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Cannot read owned fixture");
  CC_SHA256_CTX state;
  CC_SHA256_Init(&state);
  char buffer[65536];
  while (input) { input.read(buffer, sizeof(buffer)); CC_SHA256_Update(&state, buffer, static_cast<CC_LONG>(input.gcount())); }
  if (!input.eof()) throw std::runtime_error("Cannot hash owned fixture");
  unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes, &state);
  std::string result; const char *hex = "0123456789abcdef";
  for (auto byte : bytes) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void inside(const fs::path &root, const fs::path &path) {
  auto relative = path.lexically_normal().lexically_relative(root);
  require(!relative.empty() && *relative.begin() != "..", "Path is not inside owned root");
  auto current = root;
  for (const auto &part : relative) { current /= part; require(!fs::is_symlink(current), "Fixture path contains a symlink"); }
}
void denied_open(const std::string &path, int flags) {
  errno = 0; int fd = open(path.c_str(), flags | O_NOFOLLOW);
  int error = errno;
  if (fd >= 0) close(fd); // Never modify/read the canary even if isolation fails.
  require(fd < 0 && (error == EPERM || error == EACCES), "Outside-root file access was not denied");
}
void restrictions(const fs::path &root, const std::string &canary) {
  denied_open(canary, O_RDONLY);
  denied_open(canary, O_WRONLY);
  // These are actual socket operations, not sandbox-check guesses. No server
  // or remote address is used. Unsandboxed loopback refusal is a test failure.
  for (int family : {AF_INET, AF_INET6}) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) { require(errno == EPERM || errno == EACCES, "Unexpected socket failure"); continue; }
    sockaddr_storage storage{}; socklen_t size;
    if (family == AF_INET) {
      auto *address = reinterpret_cast<sockaddr_in *>(&storage);
      address->sin_family = AF_INET; address->sin_port = htons(9);
      address->sin_addr.s_addr = htonl(INADDR_LOOPBACK); size = sizeof(*address);
    } else {
      auto *address = reinterpret_cast<sockaddr_in6 *>(&storage);
      address->sin6_family = AF_INET6; address->sin6_port = htons(9);
      address->sin6_addr = in6addr_loopback; size = sizeof(*address);
    }
    int status = connect(fd, reinterpret_cast<sockaddr *>(&storage), size), error = errno;
    close(fd); require(status < 0 && (error == EPERM || error == EACCES), "Network was not denied");
  }
  auto path = root / "allowed-write-canary";
  int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
  require(fd >= 0, "Private-root writes unavailable"); close(fd); unlink(path.c_str());
}
void metal_test() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  require(device != nil, "Sandbox did not expose a Metal device");
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal; kernel void canary(device uint *out [[buffer(0)]]) { out[0] = 2871; }";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  require(library != nil, "Sandbox Metal shader compilation unavailable");
  id<MTLFunction> function = [library newFunctionWithName:@"canary"];
  id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
  require(pipeline != nil, "Sandbox Metal pipeline unavailable");
  id<MTLBuffer> buffer = [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  require(buffer != nil && queue != nil, "Sandbox Metal resources unavailable");
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
  [encoder setComputePipelineState:pipeline]; [encoder setBuffer:buffer offset:0 atIndex:0];
  [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
  [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
  require(command.status == MTLCommandBufferStatusCompleted && *static_cast<uint32_t *>(buffer.contents) == 2871,
          "Sandbox Metal computation failed");
}
template<class T> T symbol(void *image, const char *name) {
  auto result = reinterpret_cast<T>(dlsym(image, name));
  require(result != nullptr, "Required oracle C export missing"); return result;
}
std::string copy_text(const char *text) {
  if (!text) return "";
  const auto size = strnlen(text, 1024 * 1024);
  require(size < 1024 * 1024, "Oracle output exceeded bound"); return std::string(text, size);
}
int main(int argc, char **argv) {
  umask(0077);
  @autoreleasepool {
    try {
      require(argc == 4 || argc == 8, "Expected --self-test ROOT CANARY or --run ROOT CANARY IMAGE IMAGE_SHA MODEL PROMPT");
      const bool self_test = std::string(argv[1]) == "--self-test";
      require(self_test ? argc == 4 : (argc == 8 && std::string(argv[1]) == "--run"), "Invalid oracle mode");
      const auto root = fs::path(argv[2]).lexically_normal();
      require(root.is_absolute() && !fs::is_symlink(root), "Root must be a canonical absolute directory");
      struct stat st{}; require(stat(root.c_str(), &st) == 0 && st.st_uid == getuid() && (st.st_mode & 0077) == 0,
                               "Oracle root must be private and owned");
      restrictions(root, argv[3]);
      if (self_test) {
        metal_test(); std::cout << "{\"isolation\":true,\"metal\":true,\"original_loaded\":false}\n"; return 0;
      }
      const auto image_path = fs::path(argv[4]).lexically_normal(), model = fs::path(argv[6]).lexically_normal(), prompt_path = fs::path(argv[7]).lexically_normal();
      inside(root, image_path); inside(root, model); inside(root, prompt_path);
      require(digest(image_path) == argv[5], "Owned image digest differs from preparation receipt");
      require(fs::file_size(model) == 179437568 && digest(model) == model_digest, "Dedicated model digest mismatch");
      std::ifstream input(prompt_path, std::ios::binary); std::string prompt((std::istreambuf_iterator<char>(input)), {});
      require(input.eof() || !input.fail(), "Cannot read fixture prompt");
      require(prompt.size() <= 65536 && prompt.find('\0') == std::string::npos, "Invalid fixture prompt");
      // The external launcher has already installed the sandbox; restrictions
      // were rechecked before this first original-code load. No main is called.
      // Original native libraries may print to fd 1. Keep their diagnostics
      // in the private stderr file rather than contaminating fixture output.
      const int answer_fd = dup(STDOUT_FILENO);
      require(answer_fd >= 0 && dup2(STDERR_FILENO, STDOUT_FILENO) >= 0, "Cannot isolate oracle output");
      void *image = dlopen(image_path.c_str(), RTLD_NOW | RTLD_LOCAL);
      if (!image) throw std::runtime_error(std::string("Owned oracle dlopen failed: ") + dlerror());
      auto create = symbol<void *(*)(const Options *, char **)>(image, "CreateTextCacheTask");
      auto generate = symbol<char *(*)(void *, const Input *, char **)>(image, "TextCacheTask_Generate");
      auto close_task = symbol<char *(*)(void *)>(image, "TextCacheTask_Close");
      auto destroy = symbol<void (*)(void *)>(image, "DestroyTextCacheTask");
      auto free_text = symbol<void (*)(void *)>(image, "FreeTextOutput");
      auto free_error = symbol<void (*)(void *)>(image, "FreeTextCacheTaskErrorMessage");
      // Original C options pass temperature=0; CreateSession at 0x101b7a0dc
      // substitutes 0.3 whenever temperature<=0. Keep that exact input contract.
      Options options{model.c_str(), 35, 0, "", 0, 0.0f, 1, 512, "", "$CONTEXT$", "$USER_INPUT$"};
      char *error = nullptr; void *task = create(&options, &error);
      if (!task) {
        auto message = copy_text(error); free_error(error);
        throw std::runtime_error("Oracle create failed: " + message);
      }
      free_error(error); error = nullptr;
      Input request{"", prompt.c_str()}; char *output = generate(task, &request, &error);
      std::string response, generation_error, close_error;
      try { response = copy_text(output); generation_error = copy_text(error); }
      catch (...) { free_text(output); free_error(error); char *failure = close_task(task); free_error(failure); destroy(task); throw; }
      free_text(output); free_error(error);
      char *failure = close_task(task);
      try { close_error = copy_text(failure); }
      catch (...) { free_error(failure); destroy(task); throw; }
      free_error(failure); destroy(task);
      require(generation_error.empty(), ("Oracle generation failed: " + generation_error).c_str());
      require(close_error.empty(), ("Oracle close failed: " + close_error).c_str());
      // Output is public fixture text only. The launcher owns a private file.
      size_t offset = 0;
      while (offset < response.size()) {
        const auto count = write(answer_fd, response.data() + offset, response.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        require(count > 0, "Cannot write oracle fixture output"); offset += static_cast<size_t>(count);
      }
      close(answer_fd);
      // No dlclose: the original image owns process-wide C++ registries/threads.
      return 0;
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
  }
}
