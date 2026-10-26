#include "helper_control.grpc.pb.h"
#include "rag_service.grpc.pb.h"
#include "transcript_index.grpc.pb.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <future>
#include <grpcpp/grpcpp.h>
#include <iostream>
#include <iterator>
#include <signal.h>
#include <sqlite3.h>
#include <sstream>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>
namespace t = foresight::transcript::v1;
namespace r = foresight::helper::v1;
namespace c = foresight::linux::control::v1;
namespace fs = std::filesystem;
#define REQUIRE(x)                                                             \
  do {                                                                         \
    if (!(x))                                                                  \
      throw std::runtime_error(std::string(__FILE__) + ":" +                   \
                               std::to_string(__LINE__) + ": " + #x);          \
  } while (0)
template <class F> auto call(F fn) {
  grpc::ClientContext context;
  context.set_deadline(std::chrono::system_clock::now() +
                       std::chrono::seconds(10));
  return fn(&context);
}
struct Fixture {
  std::string helper, dir, socket;
  pid_t pid = -1;
  std::shared_ptr<grpc::Channel> channel;
  std::unique_ptr<t::TranscriptIndex::Stub> transcript;
  std::unique_ptr<r::RagService::Stub> rag;
  std::unique_ptr<c::HelperControl::Stub> control;
  explicit Fixture(const char *executable)
      : helper(executable), dir(fs::temp_directory_path().string() +
                                "/of-transcript-" + std::to_string(getpid())),
        socket(dir + "/run/helper.sock") {
    fs::create_directory(dir);
    chmod(dir.c_str(), 0700);
    start();
  }
  ~Fixture() {
    stop();
    fs::remove_all(dir);
  }
  void stop() {
    if (pid > 0) {
      kill(pid, SIGKILL);
      waitpid(pid, nullptr, 0);
      pid = -1;
    }
  }
  void start() {
    pid = fork();
    if (!pid) {
      execl(helper.c_str(), helper.c_str(), socket.c_str(), dir.c_str(),
            "--allow-test-models", static_cast<char *>(nullptr));
      _exit(127);
    }
    grpc::ChannelArguments args;
    args.SetInt(GRPC_ARG_USE_LOCAL_SUBCHANNEL_POOL, 1);
    channel = grpc::CreateCustomChannel(
        "unix:" + socket, grpc::InsecureChannelCredentials(), args);
    REQUIRE(channel->WaitForConnected(std::chrono::system_clock::now() +
                                      std::chrono::seconds(10)));
    transcript = t::TranscriptIndex::NewStub(channel);
    rag = r::RagService::NewStub(channel);
    control = c::HelperControl::NewStub(channel);
    configure();
  }
  void configure(const std::string &cache = "") {
    r::UpdateModelPathsRequest request;
    request.set_embedding_model_path("test://deterministic");
    request.set_cache_dir(cache);
    r::UpdateModelPathsResponse response;
    const auto status = call([&](auto *ctx) {
      return rag->UpdateModelPaths(ctx, request, &response);
    });
    if (!status.ok())
      throw std::runtime_error(status.error_message());
    REQUIRE(response.success());
  }
  t::TranscriptCursor cursor(const std::string &id) {
    t::TranscriptCursorRequest request;
    request.set_document_id(id);
    t::TranscriptCursor response;
    REQUIRE(call([&](auto *ctx) {
              return transcript->GetCursor(ctx, request, &response);
            }).ok());
    return response;
  }
  t::TranscriptDeltaResult apply(const t::TranscriptDelta &delta) {
    t::TranscriptDeltaResult response;
    const auto status = call([&](auto *ctx) {
      return transcript->ApplyDelta(ctx, delta, &response);
    });
    if (!status.ok())
      throw std::runtime_error(status.error_message());
    REQUIRE(response.revision() == delta.revision());
    return response;
  }
  r::RetrieveResponse search(const std::string &id, const std::string &text) {
    r::RetrieveRequest request;
    request.mutable_query()->set_text_query(text);
    request.set_max_results(500);
    request.set_min_similarity_score(.99999);
    request.add_allowed_document_ids(id);
    r::RetrieveResponse response;
    REQUIRE(call([&](auto *ctx) {
              return rag->RetrieveContext(ctx, request, &response);
            }).ok());
    for (const auto &chunk : response.chunks())
      REQUIRE(chunk.document_id() == id);
    return response;
  }
  int64_t scalar(const std::string &member, const char *sql) {
    sqlite3 *db = nullptr;
    REQUIRE(sqlite3_open_v2((dir + "/" + member).c_str(), &db,
                            SQLITE_OPEN_READONLY, nullptr) == SQLITE_OK);
    sqlite3_stmt *statement = nullptr;
    REQUIRE(sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) == SQLITE_OK);
    REQUIRE(sqlite3_step(statement) == SQLITE_ROW);
    const auto result = sqlite3_column_int64(statement, 0);
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return result;
  }
};
t::TranscriptDelta delta(const std::string &id, uint64_t previous,
                         uint64_t next) {
  t::TranscriptDelta result;
  result.set_document_id(id);
  result.set_workspace_epoch("controlled-epoch");
  result.set_expected_revision(previous);
  result.set_revision(next);
  return result;
}
void segment(
    t::TranscriptDelta &request, uint64_t id, const std::string &text,
    t::TranscriptKey_Channel channel = t::TranscriptKey_Channel_MICROPHONE) {
  auto *segment = request.add_upserts();
  segment->mutable_key()->set_segment_id(id);
  segment->mutable_key()->set_channel(channel);
  segment->set_text(text);
  segment->set_start_ms(id * 1000);
  segment->set_end_ms(id * 1000 + 900);
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  try {
    Fixture f(argv[1]);
    REQUIRE(!f.cursor("meeting-source").exists());
    auto first = delta("meeting-source", 0, 1);
    first.set_reset(true);
    segment(first, 1, "early microphone evidence");
    REQUIRE(f.apply(first).embedded_chunks() == 1);
    const auto retry = f.apply(first);
    REQUIRE(!retry.applied() && retry.embedded_chunks() == 0 &&
            retry.tokenized_bytes() == 0);
    auto conflict = first;
    conflict.mutable_upserts(0)->set_text("conflicting replay");
    t::TranscriptDeltaResult ignored;
    REQUIRE(call([&](auto *ctx) {
              return f.transcript->ApplyDelta(ctx, conflict, &ignored);
            }).error_code() == grpc::StatusCode::ABORTED);
    auto second = delta("meeting-source", 1, 2);
    segment(second, 2, "remote playback evidence",
            t::TranscriptKey_Channel_PLAYBACK);
    REQUIRE(f.apply(second).embedded_chunks() == 1);
    REQUIRE(f.cursor("meeting-source").last_segment_id() == 2);
    REQUIRE(f.cursor("meeting-source").segment_count() == 2);
    REQUIRE(
        f.search("meeting-source", "early microphone evidence").chunks_size() ==
        1);
    REQUIRE(
        f.search("meeting-source", "remote playback evidence").chunks_size() ==
        1);
    auto amendment = delta("meeting-source", 2, 3);
    segment(amendment, 1, "amended microphone evidence");
    REQUIRE(f.apply(amendment).embedded_chunks() == 1);
    REQUIRE(
        f.search("meeting-source", "early microphone evidence").chunks_size() ==
        0);
    REQUIRE(
        f.search("meeting-source", "remote playback evidence").chunks_size() ==
        1);
    auto remove = delta("meeting-source", 3, 4);
    auto *key = remove.add_deletes();
    key->set_segment_id(2);
    key->set_channel(t::TranscriptKey_Channel_PLAYBACK);
    REQUIRE(f.apply(remove).embedded_chunks() == 0);
    REQUIRE(f.cursor("meeting-source").last_segment_id() == 2);
    REQUIRE(f.cursor("meeting-source").segment_count() == 1);
    REQUIRE(
        f.search("meeting-source", "remote playback evidence").chunks_size() ==
        0);
    auto finalized = delta("meeting-source", 4, 5);
    const auto final = f.apply(finalized);
    REQUIRE(final.embedded_chunks() == 0 && final.tokenized_bytes() == 0);
    // A held precommit transaction never blocks searches or exposes new rows.
    std::ofstream(f.dir + "/.pause-at") << "transcript_before_commit";
    auto atomic = delta("meeting-source", 5, 6);
    segment(atomic, 3, "freshdelta atomicsearch uniquelytimed");
    auto pending =
        std::async(std::launch::async, [&] { return f.apply(atomic); });
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!fs::exists(f.dir + "/.paused") &&
           std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    REQUIRE(fs::exists(f.dir + "/.paused"));
    REQUIRE(f.search("meeting-source", "amended microphone evidence")
                .chunks_size() == 1);
    REQUIRE(f.search("meeting-source", "freshdelta atomicsearch uniquelytimed")
                .chunks_size() == 0);
    fs::remove(f.dir + "/.pause-at");
    REQUIRE(pending.get().applied());
    fs::remove(f.dir + "/.paused");
    REQUIRE(f.search("meeting-source", "freshdelta atomicsearch uniquelytimed")
                .chunks_size() == 1);
    // Cancellation settles the actual writer before the next cursor/append.
    std::ofstream(f.dir + "/.pause-at") << "partial_vectors";
    auto canceled_delta = delta("meeting-source", 6, 7);
    segment(canceled_delta, 4, "canceled evidence must not publish");
    grpc::ClientContext cancellation;
    cancellation.set_deadline(std::chrono::system_clock::now() +
                              std::chrono::seconds(5));
    auto canceled = std::async(std::launch::async, [&] {
      t::TranscriptDeltaResult response;
      return f.transcript->ApplyDelta(&cancellation, canceled_delta, &response);
    });
    const auto cancel_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!fs::exists(f.dir + "/.paused") &&
           std::chrono::steady_clock::now() < cancel_deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    REQUIRE(fs::exists(f.dir + "/.paused"));
    cancellation.TryCancel();
    REQUIRE(canceled.get().error_code() == grpc::StatusCode::CANCELLED);
    fs::remove(f.dir + "/.pause-at");
    REQUIRE(f.cursor("meeting-source").revision() == 6);
    REQUIRE(f.cursor("meeting-source").last_segment_id() == 3);
    REQUIRE(f.search("meeting-source", "canceled evidence must not publish")
                .chunks_size() == 0);
    fs::remove(f.dir + "/.paused");
    auto duplicate = delta("meeting-source", 6, 7);
    segment(duplicate, 9, "one");
    segment(duplicate, 9, "two");
    REQUIRE(call([&](auto *ctx) {
              return f.transcript->ApplyDelta(ctx, duplicate, &ignored);
            }).error_code() == grpc::StatusCode::INVALID_ARGUMENT);
    auto oversized = delta("meeting-source", 6, 7);
    segment(oversized, 9, std::string(65537, 'x'));
    REQUIRE(call([&](auto *ctx) {
              return f.transcript->ApplyDelta(ctx, oversized, &ignored);
            }).error_code() == grpc::StatusCode::INVALID_ARGUMENT);
    auto wrong_epoch = delta("meeting-source", 6, 7);
    wrong_epoch.set_workspace_epoch("stale-workspace");
    REQUIRE(call([&](auto *ctx) {
              return f.transcript->ApplyDelta(ctx, wrong_epoch, &ignored);
            }).error_code() == grpc::StatusCode::ABORTED);
    REQUIRE(f.cursor("meeting-source").revision() == 6);
    for (const auto *boundary :
         {"transcript_before_commit", "transcript_after_commit"}) {
      const auto prior_cursor = f.cursor("meeting-source");
      const auto previous = prior_cursor.revision();
      auto crashed = delta("meeting-source", previous, previous + 1);
      segment(crashed, previous + 10, boundary);
      std::ofstream(f.dir + "/.crash-at") << boundary;
      t::TranscriptDeltaResult response;
      REQUIRE(!call([&](auto *ctx) {
                 return f.transcript->ApplyDelta(ctx, crashed, &response);
               }).ok());
      int status = 0;
      REQUIRE(waitpid(f.pid, &status, 0) == f.pid);
      f.pid = -1;
      REQUIRE(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
      fs::remove(f.dir + "/.crash-at");
      f.start();
      const bool committed = std::string(boundary) == "transcript_after_commit";
      REQUIRE(f.cursor("meeting-source").revision() == previous + committed);
      REQUIRE(f.cursor("meeting-source").last_segment_id() ==
              (committed ? previous + 10 : prior_cursor.last_segment_id()));
      const auto replay = f.apply(crashed);
      REQUIRE(replay.applied() != committed);
      if (committed)
        REQUIRE(replay.tokenized_bytes() == 0);
    }
    f.stop();
    f.start();
    REQUIRE(f.search("meeting-source", "amended microphone evidence")
                .chunks_size() == 1);
    f.configure(f.dir + "/replacement-cache");
    REQUIRE(f.search("meeting-source", "amended microphone evidence")
                .chunks_size() == 1);
    REQUIRE(f.scalar("rag_vector.db", "SELECT COUNT(*) FROM generations") == 1);
    const auto previous = f.cursor("meeting-source").revision();
    auto reset = delta("meeting-source", previous, 1);
    reset.set_reset(true);
    reset.set_workspace_epoch("replacement-epoch");
    segment(reset, 1, "replacement workspace evidence");
    REQUIRE(f.apply(reset).applied());
    REQUIRE(f.search("meeting-source", "amended microphone evidence")
                .chunks_size() == 0);
    REQUIRE(f.search("meeting-source", "replacement workspace evidence")
                .chunks_size() == 1);
    r::DeleteRequest deletion;
    deletion.set_document_id("meeting-source");
    r::DeleteResponse deleted;
    REQUIRE(call([&](auto *ctx) {
              return f.rag->DeleteDocument(ctx, deletion, &deleted);
            }).ok());
    REQUIRE(!f.cursor("meeting-source").exists());
    REQUIRE(f.scalar("linux_state.db",
                     "SELECT COUNT(*) FROM transcript_segments") == 0);
    REQUIRE(f.scalar("agent_metadata.db", "SELECT COUNT(*) FROM documents") ==
            0);
    REQUIRE(f.scalar("rag_vector.db", "SELECT COUNT(*) FROM chunks") == 0);
    for (const auto *member :
         {"agent_metadata.db", "linux_state.db", "rag_vector.db"}) {
      std::ifstream input(f.dir + "/" + member, std::ios::binary);
      const std::string bytes((std::istreambuf_iterator<char>(input)), {});
      REQUIRE(bytes.find("replacement workspace evidence") ==
              std::string::npos);
      REQUIRE(bytes.find("amended microphone evidence") == std::string::npos);
    }
    f.stop();
    f.start();
    REQUIRE(f.search("meeting-source", "replacement workspace evidence")
                .chunks_size() == 0);
    // Fixed workload, fixed N and threshold declared before measurements.
    // Each immutable segment has exactly the same ASCII text; no model/startup
    // work is charged to these per-request counters. No full parent is resent.
    constexpr int n = 64;
    const std::string text = "bounded transcript evidence with stable segment "
                             "identity and parent citation";
    uint64_t processed[2] = {}, tokens[2] = {}, chunks[2] = {},
             constructed[2] = {};
    // Linux ticks are coarse, and include instrumentation in this process.
    // The child is the exact fork/exec PID owned by Fixture, never inferred.
    auto cpu_ticks = [](pid_t pid) {
      std::pair<uint64_t, uint64_t> ticks{};
#ifdef __linux__
      std::ifstream input("/proc/" + std::to_string(pid) + "/stat");
      std::string line;
      REQUIRE(bool(std::getline(input, line)));
      std::istringstream fields(line.substr(line.rfind(')') + 2));
      std::string field;
      for (int i = 0; i <= 12; ++i) {
        REQUIRE(bool(fields >> field));
        if (i == 11)
          ticks.first = std::stoull(field);
        if (i == 12)
          ticks.second = std::stoull(field);
      }
#else
      (void)pid;
#endif
      return ticks;
    };
    auto storage_bytes = [&](const std::string &suffix) {
      uint64_t bytes = 0;
      for (const auto *member :
           {"agent_metadata.db", "linux_state.db", "rag_vector.db"}) {
        const auto path = f.dir + "/" + member + suffix;
        if (fs::exists(path))
          bytes += fs::file_size(path);
      }
      return bytes;
    };
    for (int run = 0; run < 2; ++run) {
      const auto parent = std::string("linear-") + std::to_string(run);
      const auto parent_cpu = cpu_ticks(getpid());
      const auto child_cpu = cpu_ticks(f.pid);
      const auto db_before = storage_bytes("");
      const auto wal_before = storage_bytes("-wal");
      std::vector<int64_t> apply_us;
      apply_us.reserve(n * (run + 1));
      for (int i = 1; i <= n * (run + 1); ++i) {
        auto request = delta(parent, i - 1, i);
        segment(request, i, text);
        if (i == 1)
          request.set_reset(true);
        const auto rpc_start = std::chrono::steady_clock::now();
        const auto response = f.apply(request);
        apply_us.push_back(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - rpc_start)
                .count());
        processed[run] +=
            response.tokenized_bytes() + response.embedded_bytes();
        tokens[run] += response.tokenized_tokens();
        chunks[run] += response.embedded_chunks();
        constructed[run] += response.snapshot_constructed_chunks();
      }
      const auto search_start = std::chrono::steady_clock::now();
      REQUIRE(f.search(parent, text).chunks_size() == n * (run + 1));
      const auto search_us =
          std::chrono::duration_cast<std::chrono::microseconds>(
              std::chrono::steady_clock::now() - search_start)
              .count();
      const auto parent_after = cpu_ticks(getpid());
      const auto child_after = cpu_ticks(f.pid);
      const auto db_after = storage_bytes("");
      const auto wal_after = storage_bytes("-wal");
      std::cout
          << "F3_HELPER_RESOURCES segments=" << n * (run + 1)
#ifdef __linux__
          << " cpu_supported=1"
#else
          << " cpu_supported=0"
#endif
          << " ticks_per_second=" << sysconf(_SC_CLK_TCK)
          << " parent_user_ticks=" << parent_after.first - parent_cpu.first
          << " parent_system_ticks=" << parent_after.second - parent_cpu.second
          << " owned_child_user_ticks=" << child_after.first - child_cpu.first
          << " owned_child_system_ticks="
          << child_after.second - child_cpu.second
          << " database_bytes_before=" << db_before
          << " database_bytes_after=" << db_after
          << " database_bytes_delta=" << int64_t(db_after) - int64_t(db_before)
          << " wal_bytes_before=" << wal_before
          << " wal_bytes_after=" << wal_after
          << " wal_bytes_delta=" << int64_t(wal_after) - int64_t(wal_before)
          << " db_scope=cumulative_fixture_including_previous_documents"
          << " search_rpc_us=" << search_us << " apply_rpc_us=";
      for (const auto us : apply_us)
        std::cout << us << ',';
      std::cout << '\n';
      std::cout << "segments=" << n * (run + 1)
                << " processed_bytes=" << processed[run]
                << " tokenized_tokens=" << tokens[run]
                << " embedded_chunks=" << chunks[run]
                << " snapshot_constructed_chunks=" << constructed[run] << '\n';
    }
    REQUIRE(processed[0] > 0 && double(processed[1]) / processed[0] <= 2.5);
    REQUIRE(processed[1] == 2 * processed[0] && tokens[1] == 2 * tokens[0] &&
            chunks[1] == 2 * chunks[0]);
    REQUIRE(f.scalar("agent_metadata.db", "SELECT COUNT(*) FROM documents") ==
            3 * n);
    REQUIRE(f.scalar("agent_metadata.db",
                     "SELECT COUNT(*) FROM documents WHERE id "
                     "IN ('linear-0','linear-1')") == 0);
    const auto stop_start = std::chrono::steady_clock::now();
    f.stop();
    std::cout << "F3_HELPER_EXISTING_KILL_AND_WAIT_US="
              << std::chrono::duration_cast<std::chrono::microseconds>(
                     std::chrono::steady_clock::now() - stop_start)
                     .count()
              << '\n';
    fs::remove(f.dir + "/agent_metadata.db");
    f.start();
    REQUIRE(!f.cursor("linear-0").exists());
    REQUIRE(f.search("linear-0", text).chunks_size() == 0);
    auto recovered = delta("recovered-parent", 0, 1);
    recovered.set_reset(true);
    segment(recovered, 1, "recovered owned transcript evidence");
    REQUIRE(f.apply(recovered).applied());
    f.stop();
    fs::remove(f.dir + "/linux_state.db");
    f.start();
    REQUIRE(!f.cursor("recovered-parent").exists());
    REQUIRE(f.scalar("agent_metadata.db", "SELECT COUNT(*) FROM documents") ==
            0);
    REQUIRE(f.search("recovered-parent", "recovered owned transcript evidence")
                .chunks_size() == 0);
    REQUIRE(f.apply(recovered).applied());
    REQUIRE(f.search("recovered-parent", "recovered owned transcript evidence")
                .chunks_size() == 1);
    std::cout << "Transcript index contracts passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
