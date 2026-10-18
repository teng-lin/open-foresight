#include "helper_control.grpc.pb.h"
#include "model.h"
#include "research/xeno/labs/foresight/launch_agent/proto/rag_service.grpc.pb.h"
#include <grpcpp/grpcpp.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc.h>
#endif
#include <chrono>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>

#define REQUIRE(value)                                                         \
  do {                                                                         \
    if (!(value))                                                              \
      throw std::runtime_error(#value);                                        \
  } while (0)

namespace p = research::xeno::labs::foresight::launch_agent::proto;
namespace c = foresight::linux::control::v1;

static bool dead(pid_t pid) {
#ifdef __APPLE__
  proc_bsdinfo info{};
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) !=
             sizeof(info) ||
         info.pbi_status == SZOMB;
#else
  std::ifstream status("/proc/" + std::to_string(pid) + "/stat");
  std::string line;
  std::getline(status, line);
  if (line.empty())
    return true;
  auto state = line.find_last_of(')');
  return state != std::string::npos && line[state + 2] == 'Z';
#endif
}

static void private_dir(const fs::path &path) {
  fs::create_directories(path);
  REQUIRE(chmod(path.c_str(), 0700) == 0);
}

static pid_t last_pid(const fs::path &log) {
  std::ifstream input(log);
  std::string line, last;
  while (std::getline(input, line))
    if (!line.empty())
      last = line;
  return last.empty() ? -1 : static_cast<pid_t>(std::atoi(last.c_str()));
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  // macOS sockaddr_un.sun_path is 104 bytes including NUL. Hosted TMPDIR is
  // already a long /var/folders path, so the helper socket stays under /tmp.
  const fs::path root =
      fs::path("/tmp") / ("of-af-" + std::to_string(getpid()));
  pid_t helpers[2] = {-1, -1};
  try {
    REQUIRE(argc == 3);
    fs::remove_all(root);
    const fs::path model_path = root / "model.litertlm";
    private_dir(root);
    std::ofstream(model_path) << "controlled embedding fixture";
    setenv("FORESIGHT_MODEL_WORKER", argv[2], 1);
    unsetenv("FORESIGHT_FIXTURE_FAIL_ENCODE");
    setenv("FORESIGHT_FIXTURE_STALL_AFTER", "0", 1);
    setenv("FORESIGHT_ADAPTER_DEADLINE_MS", "400", 1);

    pid_t worker = -1;
    const auto started = std::chrono::steady_clock::now();
    bool timed_out = false;
    try {
      Model model(model_path.string(), false);
      worker = model.worker_pid();
      REQUIRE(worker > 0);
      model.encode("hello");
      REQUIRE(false);
    } catch (const std::exception &error) {
      timed_out =
          std::string(error.what()).find("timed out") != std::string::npos;
    }
    const auto direct_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started)
            .count();
    REQUIRE(timed_out);
    REQUIRE(direct_ms >= 300 && direct_ms < 2000);
    REQUIRE(worker > 0);
    REQUIRE(dead(worker));
    std::cout << "direct stall returned in " << direct_ms
              << " ms and killed worker " << worker << "\n";

    const fs::path storage = root / "storage";
    const fs::path socket = storage / "helper.sock";
    const fs::path flag = root / "stall.flag";
    const fs::path pid_log = root / "workers.log";
    private_dir(storage);
    setenv("FORESIGHT_FIXTURE_STALL_AFTER", "1", 1);
    setenv("FORESIGHT_ADAPTER_DEADLINE_MS", "800", 1);
    setenv("FORESIGHT_FIXTURE_STALL_FLAG", flag.c_str(), 1);
    setenv("FORESIGHT_FIXTURE_PID_LOG", pid_log.c_str(), 1);
    helpers[0] = fork();
    REQUIRE(helpers[0] >= 0);
    if (helpers[0] == 0) {
      execl(argv[1], argv[1], socket.c_str(), storage.c_str(),
            static_cast<char *>(nullptr));
      _exit(127);
    }
    auto channel = grpc::CreateChannel("unix:" + socket.string(),
                                       grpc::InsecureChannelCredentials());
    REQUIRE(channel->WaitForConnected(std::chrono::system_clock::now() +
                                      std::chrono::seconds(10)));
    auto stub = p::RagService::NewStub(channel);
    auto control = c::HelperControl::NewStub(channel);
    p::UpdateModelPathsRequest model;
    model.set_embedding_model_path(model_path.string());
    p::UpdateModelPathsResponse configured;
    grpc::ClientContext configure;
    configure.set_deadline(std::chrono::system_clock::now() +
                           std::chrono::seconds(5));
    REQUIRE(stub->UpdateModelPaths(&configure, model, &configured).ok());
    REQUIRE(configured.success());

    grpc::Status encode_status;
    long encode_ms = 0;
    std::thread encoding([&] {
      const auto encode_started = std::chrono::steady_clock::now();
      p::EncodeRequest request;
      request.set_text("hello");
      p::EncodeResponse response;
      grpc::ClientContext context;
      context.set_deadline(std::chrono::system_clock::now() +
                           std::chrono::seconds(5));
      encode_status = stub->Encode(&context, request, &response);
      encode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - encode_started)
                      .count();
    });
    const auto flag_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!fs::exists(flag) &&
           std::chrono::steady_clock::now() < flag_deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    REQUIRE(fs::exists(flag));
    const auto state_started = std::chrono::steady_clock::now();
    c::Empty empty;
    c::State during;
    grpc::ClientContext during_state;
    during_state.set_deadline(std::chrono::system_clock::now() +
                              std::chrono::seconds(2));
    REQUIRE(control->GetState(&during_state, empty, &during).ok());
    const auto state_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - state_started)
                              .count();
    REQUIRE(state_ms < 250);
    const auto delete_started = std::chrono::steady_clock::now();
    p::DeleteRequest deletion;
    p::DeleteResponse deleted;
    grpc::ClientContext delete_context;
    delete_context.set_deadline(std::chrono::system_clock::now() +
                                std::chrono::seconds(2));
    (void)stub->DeleteDocument(&delete_context, deletion, &deleted);
    const auto delete_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - delete_started)
            .count();
    REQUIRE(delete_ms < 400);
    encoding.join();
    REQUIRE(encode_ms >= 600 && encode_ms < 3000);
    REQUIRE(!encode_status.ok());
    REQUIRE(encode_status.error_code() == grpc::StatusCode::INTERNAL);
    const pid_t stalled = last_pid(pid_log);
    REQUIRE(stalled > 0);
    REQUIRE(dead(stalled));
    c::State after;
    grpc::ClientContext after_state;
    after_state.set_deadline(std::chrono::system_clock::now() +
                             std::chrono::seconds(2));
    REQUIRE(control->GetState(&after_state, empty, &after).ok());
    REQUIRE(after.pipeline() != "ready");
    REQUIRE(after.pipeline() == "failed");
    REQUIRE(!after.tokenizer_ready());
    std::cout << "delete during stall returned in " << delete_ms
              << " ms; get-state in " << state_ms
              << " ms; stalled encode status "
              << static_cast<int>(encode_status.error_code()) << " pipeline "
              << after.pipeline() << "\n";
    kill(helpers[0], SIGTERM);
    waitpid(helpers[0], nullptr, 0);
    helpers[0] = -1;

    unsetenv("FORESIGHT_FIXTURE_STALL_AFTER");
    unsetenv("FORESIGHT_FIXTURE_STALL_FLAG");
    setenv("FORESIGHT_FIXTURE_FAIL_ENCODE", "1", 1);
    const fs::path failed_storage = root / "storage-fail";
    const fs::path failed_socket = failed_storage / "helper.sock";
    private_dir(failed_storage);
    helpers[1] = fork();
    REQUIRE(helpers[1] >= 0);
    if (helpers[1] == 0) {
      execl(argv[1], argv[1], failed_socket.c_str(), failed_storage.c_str(),
            static_cast<char *>(nullptr));
      _exit(127);
    }
    auto failed_channel = grpc::CreateChannel(
        "unix:" + failed_socket.string(), grpc::InsecureChannelCredentials());
    REQUIRE(failed_channel->WaitForConnected(std::chrono::system_clock::now() +
                                             std::chrono::seconds(10)));
    auto failed_stub = p::RagService::NewStub(failed_channel);
    grpc::ClientContext failed_configure;
    failed_configure.set_deadline(std::chrono::system_clock::now() +
                                  std::chrono::seconds(5));
    p::UpdateModelPathsResponse failed_configured;
    REQUIRE(failed_stub
                ->UpdateModelPaths(&failed_configure, model, &failed_configured)
                .ok());
    REQUIRE(failed_configured.success());
    p::EncodeRequest failed_request;
    failed_request.set_text("hello");
    p::EncodeResponse failed_response;
    grpc::ClientContext failed_encode;
    failed_encode.set_deadline(std::chrono::system_clock::now() +
                               std::chrono::seconds(5));
    const auto failed_status =
        failed_stub->Encode(&failed_encode, failed_request, &failed_response);
    REQUIRE(!failed_status.ok());
    REQUIRE(failed_status.error_code() == grpc::StatusCode::INTERNAL);
    REQUIRE(failed_status.error_message().find("tokenizer") !=
            std::string::npos);
    REQUIRE(failed_response.tokens_size() == 0);
    std::cout << "tokenizer encode status "
              << static_cast<int>(failed_status.error_code()) << " "
              << failed_status.error_message() << "\n";
    kill(helpers[1], SIGTERM);
    waitpid(helpers[1], nullptr, 0);
    helpers[1] = -1;
    fs::remove_all(root);
    std::cout << "helper adapter faults passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    for (pid_t helper : helpers)
      if (helper > 0) {
        kill(helper, SIGKILL);
        waitpid(helper, nullptr, 0);
      }
    fs::remove_all(root);
    return 1;
  }
}
