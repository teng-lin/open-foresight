#include "build_identity.h"
#include "helper_control.grpc.pb.h"
#include "helper_protocol_version.h"
#include "model.h"
#include "rag_service.grpc.pb.h"
#include "reconfig_wait.h"
#include "schema_migrations.h"
#include "transcript_index.grpc.pb.h"
#include "vector_index.h"
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <grpcpp/grpcpp.h>
#include <iostream>
#include <mutex>
#include <nlohmann/json.hpp>
#include <signal.h>
#include <sqlite3.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
using json = nlohmann::json;
namespace rpc = foresight::helper::v1;
namespace ctl = foresight::linux::control::v1;
namespace transcript = foresight::transcript::v1;
namespace fs = std::filesystem;
using grpc::Status;
using grpc::StatusCode;
struct Statement {
  sqlite3_stmt *p = nullptr;
  Statement(sqlite3 *db, const char *sql) {
    if (sqlite3_prepare_v2(db, sql, -1, &p, nullptr) != SQLITE_OK)
      throw std::runtime_error(sqlite3_errmsg(db));
  }
  ~Statement() {
    sqlite3_finalize(p);
  }
  void text(int n, const std::string &v) {
    sqlite3_bind_text(p, n, v.data(), v.size(), SQLITE_TRANSIENT);
  }
  void num(int n, int64_t v) {
    sqlite3_bind_int64(p, n, v);
  }
  void blob(int n, const std::string &v) {
    sqlite3_bind_blob(p, n, v.data(), v.size(), SQLITE_TRANSIENT);
  }
  bool row() {
    int r = sqlite3_step(p);
    if (r != SQLITE_ROW && r != SQLITE_DONE)
      throw std::runtime_error(sqlite3_errmsg(sqlite3_db_handle(p)));
    return r == SQLITE_ROW;
  }
  std::string str(int n) {
    const auto *b = sqlite3_column_blob(p, n);
    return b ? std::string((const char *)b, sqlite3_column_bytes(p, n)) : "";
  }
  int64_t integer(int n) {
    return sqlite3_column_int64(p, n);
  }
};
class Service : public rpc::RagService::Service,
                public ctl::HelperControl::Service,
                public transcript::TranscriptIndex::Service {
  struct SearchSnapshot {
    std::shared_ptr<Model> model;
    foresight::VectorIndexSnapshot index;
    SearchSnapshot(std::shared_ptr<Model> m,
                   foresight::VectorIndexSnapshot next)
        : model(std::move(m)), index(std::move(next)) {}
  };
  std::shared_ptr<const SearchSnapshot> search_snapshot;
  std::mutex snapshot_mu;
  void rebuild_index() {
    std::vector<foresight::IndexedChunk> chunks;
    Statement q(
        db,
        "SELECT "
        "c.text,c.document_id,c.mime,c.embedding,COALESCE(t.parent_id,'') FROM "
        "vectors.chunks c JOIN linux.source_revisions r ON "
        "r.id=c.document_id AND r.revision=c.revision LEFT JOIN "
        "linux.transcript_segments t ON t.id=c.document_id WHERE r.tombstone=0 "
        "AND c.generation=? ORDER BY c.document_id,c.ordinal");
    q.num(1, state.active_generation());
    while (q.row())
      chunks.push_back({q.str(0), q.str(1), q.str(2),
                        foresight::read_vector(q.str(3)), false, q.str(4)});
    std::shared_ptr<const SearchSnapshot> replacement =
        std::make_shared<SearchSnapshot>(
            model, foresight::VectorIndexSnapshot(std::move(chunks)));
    publish_snapshot(std::move(replacement));
  }
  std::shared_ptr<const SearchSnapshot>
  stage_index(std::set<std::string> ids,
              std::vector<foresight::IndexedChunk> chunks) {
    std::shared_ptr<const SearchSnapshot> previous;
    {
      std::lock_guard lock(snapshot_mu);
      previous = search_snapshot;
    }
    auto index = previous ? previous->index : foresight::VectorIndexSnapshot{};
    return std::make_shared<SearchSnapshot>(
        model, index.replacing(std::move(ids), std::move(chunks)));
  }
  void publish_snapshot(std::shared_ptr<const SearchSnapshot> replacement) {
    {
      std::lock_guard lock(snapshot_mu);
      search_snapshot.swap(replacement);
    }
    // Retire the old tree outside the pointer lock; destruction can be
    // expensive.
  }
  struct PreparedChunk {
    std::string text;
    std::vector<double> embedding;
  };
  struct DocWork {
    std::string id, content, mime;
    int size = 0, overlap = 0;
    uint64_t rev = 0;
    std::vector<PreparedChunk> chunks;
  };
  sqlite3 *db = nullptr;
  std::recursive_mutex mu;
  std::mutex view_mu, reconfig_mu;
  std::condition_variable reconfig_cv;
  bool reconfiguring = false;
  std::shared_ptr<Model> model;
  ctl::State state, view;
  bool allow_test, use_gpu = false;
  std::string path, cache, storage_root;
  struct ReconfigGuard {
    Service &s;
    bool held = false;
    explicit ReconfigGuard(Service &x) : s(x) {}
    Status enter(grpc::ServerContext *context) {
      std::unique_lock lock(s.reconfig_mu);
      const auto result = foresight::wait_for_reconfiguration(
          s.reconfig_cv, lock, s.reconfiguring,
          [&] { return context->IsCancelled(); },
          [&] {
            return std::chrono::system_clock::now() >= context->deadline();
          });
      if (result == foresight::ReconfigWait::cancelled)
        return {StatusCode::CANCELLED,
                "Cancelled while awaiting model reconfiguration"};
      if (result == foresight::ReconfigWait::deadline)
        return {StatusCode::DEADLINE_EXCEEDED,
                "Model reconfiguration wait expired"};
      if (result == foresight::ReconfigWait::busy_timeout)
        return {StatusCode::UNAVAILABLE,
                "Model reconfiguration in progress; retry"};
      s.reconfiguring = true;
      held = true;
      return Status::OK;
    }
    ~ReconfigGuard() {
      if (!held)
        return;
      std::lock_guard lock(s.reconfig_mu);
      s.reconfiguring = false;
      s.reconfig_cv.notify_all();
    }
  };
  void sql(const std::string &q) {
    char *e = nullptr;
    if (sqlite3_exec(db, q.c_str(), nullptr, nullptr, &e) != SQLITE_OK) {
      std::string msg = e ? e : "SQLite failure";
      sqlite3_free(e);
      throw std::runtime_error(msg);
    }
  }
  struct Tx {
    Service &s;
    bool done = false;
    Tx(Service &x) : s(x) {
      s.sql("BEGIN IMMEDIATE");
    }
    ~Tx() {
      if (!done)
        sqlite3_exec(s.db, "ROLLBACK", nullptr, nullptr, nullptr);
    }
    void commit() {
      s.sql("COMMIT");
      done = true;
    }
  };
  void changed() {
    state.set_revision(state.revision() + 1);
    std::lock_guard lock(view_mu);
    view = state;
  }
  void crash(const char *step) {
#if FORESIGHT_ENABLE_TEST_HOOKS
    if (!allow_test)
      return;
    // Test-only publication barrier: prove active readers never wait on the
    // writer's SQLite transaction or on construction of its replacement index.
    std::string pause;
    {
      std::ifstream file(storage_root + "/.pause-at");
      std::getline(file, pause);
    }
    if (pause == step) {
      std::ofstream(storage_root + "/.paused") << step;
      for (int i = 0; i < 100 && fs::exists(storage_root + "/.pause-at"); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    std::string value;
    std::ifstream in(storage_root + "/.crash-at");
    std::getline(in, value);
    const char *env = getenv("FORESIGHT_CRASH_AT");
    if (value == step || (env && std::string(env) == step)) {
      // Model abrupt process death at the transaction boundary. Sanitizers
      // intercept _exit and can run shutdown checks on deliberately unjoined
      // server threads; SIGKILL must bypass orderly process teardown.
      if (kill(getpid(), SIGKILL) != 0)
        _exit(86);
      // Darwin can return from kill before delivering the pending signal.
      // Do not race it with an ordinary exit or resume the transaction.
      for (;;)
        pause();
    }
#else
    (void)step;
#endif
  }
  static void require_public_document(const std::string &id) {
    if (id.empty() || id.size() > 4096 || id.find('\0') != std::string::npos)
      throw std::invalid_argument("Invalid document ID");
  }
  std::vector<std::string> transcript_ids(const std::string &parent) {
    Statement q(db,
                "SELECT id FROM linux.transcript_segments WHERE parent_id=?");
    q.text(1, parent);
    std::vector<std::string> ids;
    while (q.row())
      ids.push_back(q.str(0));
    return ids;
  }
  void erase_transcript(const std::string &parent) {
    for (const auto &id : transcript_ids(parent)) {
      for (const auto *sqltext :
           {"DELETE FROM documents WHERE id=?",
            "DELETE FROM vectors.chunks WHERE document_id=?",
            "DELETE FROM linux.source_revisions WHERE id=?",
            "DELETE FROM linux.journal WHERE document_id=?"}) {
        Statement q(db, sqltext);
        q.text(1, id);
        q.row();
      }
    }
    for (const auto *sqltext :
         {"DELETE FROM linux.transcript_segments WHERE parent_id=?",
          "DELETE FROM linux.transcript_documents WHERE document_id=?"}) {
      Statement q(db, sqltext);
      q.text(1, parent);
      q.row();
    }
  }
  static std::string transcript_id(const std::string &parent,
                                   const std::string &epoch,
                                   const transcript::TranscriptKey &key) {
    return std::string(1, '\0') +
           json::array({parent, epoch, static_cast<int>(key.channel()),
                        key.segment_id()})
               .dump();
  }
  uint64_t revision(const std::string &id) {
    Statement q(db, "SELECT revision FROM linux.source_revisions WHERE id=?");
    q.text(1, id);
    return q.row() ? q.integer(0) + 1 : 1;
  }
  void journal(const std::string &op, const std::string &id, uint64_t rev) {
    Statement q(db, "INSERT INTO "
                    "linux.journal(operation,document_id,revision,generation,"
                    "status) VALUES(?,?,?,?, 'committed')");
    q.text(1, op);
    q.text(2, id);
    q.num(3, rev);
    q.num(4, state.active_generation());
    q.row();
  }
  std::vector<PreparedChunk>
  prepare_chunks(Model &m, const std::string &content, int size, int overlap,
                 const std::string &mime, grpc::ServerContext *context) {
    if (mime.starts_with("image/")) {
      throw std::runtime_error(
          "Image embedding unavailable in text-only model");
    }
    auto texts = m.chunks(content, size, overlap);
    std::vector<PreparedChunk> prepared;
    prepared.reserve(texts.size());
    for (size_t i = 0; i < texts.size(); ++i) {
      if (context && context->IsCancelled())
        throw std::runtime_error("Index operation cancelled");
      prepared.push_back({texts[i], m.embed(texts[i])});
    }
    return prepared;
  }
  void insert_vectors(const std::vector<PreparedChunk> &chunks,
                      const std::string &id, uint64_t rev, uint64_t gen,
                      const std::string &mime, grpc::ServerContext *context) {
    // Foreground insertion is grouped in five-chunk batches, inside one atomic
    // publication.
    for (size_t batch = 0; batch < chunks.size(); batch += 5)
      for (size_t i = batch; i < std::min(chunks.size(), batch + 5); ++i) {
        if (context && context->IsCancelled())
          throw std::runtime_error("Index operation cancelled");
        Statement q(db, "INSERT INTO "
                        "vectors.chunks(generation,document_id,revision,"
                        "ordinal,text,mime,embedding) VALUES(?,?,?,?,?,?,?)");
        q.num(1, gen);
        q.text(2, id);
        q.num(3, rev);
        q.num(4, i);
        q.text(5, chunks[i].text);
        q.text(6, mime);
        q.blob(7, foresight::vector_blob(chunks[i].embedding));
        q.row();
        crash("partial_vectors");
      }
  }
  void note_adapter_failure(const std::shared_ptr<Model> &current,
                            const std::exception &e) {
    if (model == current && current && !current->available() &&
        state.pipeline() == "ready") {
      state.set_pipeline("failed");
      state.set_tokenizer_ready(false);
      state.set_index("degraded");
      state.set_last_error(e.what());
      changed();
    }
  }
  void refresh_model_health() {
    std::unique_lock lock(mu, std::try_to_lock);
    if (lock.owns_lock() && model && !model->available() &&
        state.pipeline() == "ready") {
      state.set_pipeline("failed");
      state.set_tokenizer_ready(false);
      state.set_index("degraded");
      state.set_last_error("Embedding adapter exited; reload the model");
      changed();
    }
  }
  Status absent() {
    refresh_model_health();
    return {StatusCode::UNAVAILABLE,
            model ? "Embedding adapter unavailable; reload the model"
                  : "Pipeline not initialized"};
  }
  template <class Response>
  Status app_error(Response *r, const std::exception &e,
                   grpc::ServerContext *context) {
    (void)r;
    state.set_last_error(e.what());
    changed();
    return {context->IsCancelled() ? StatusCode::CANCELLED
            : dynamic_cast<const std::invalid_argument *>(&e)
                ? StatusCode::INVALID_ARGUMENT
                : StatusCode::FAILED_PRECONDITION,
            e.what()};
  }
  std::string model_identity(const Model &m) {
    return json({"index-model-v1", m.digest, m.tokenizer_digest,
                 m.test ? "test-only-byte-tokenizer/fnv-word-v1"
                        : m.preprocessing,
                 m.backend, m.dimensions})
        .dump();
  }
  void publish_model(std::shared_ptr<Model> replacement,
                     const std::string &next, const std::string &next_cache,
                     bool next_gpu, uint64_t gen) {
    cache = next_cache;
    use_gpu = next_gpu;
    model = std::move(replacement);
    path = next;
    state.set_active_generation(gen);
    state.set_pending_generation(0);
    state.set_pipeline("ready");
    state.set_tokenizer_ready(true);
    state.set_index(state.completed() ? "ready" : "empty");
    state.set_last_error("");
    auto *identity = state.mutable_model();
    identity->set_model_digest(model->digest);
    identity->set_tokenizer_digest(model->tokenizer_digest);
    identity->set_preprocessing(model->test
                                    ? "test-only-byte-tokenizer/fnv-word-v1"
                                    : model->preprocessing);
    identity->set_backend(model->backend);
    identity->set_dimensions(model->dimensions);
    rebuild_index();
    identity->set_path(path);
    identity->clear_modalities();
    identity->add_modalities("text");
    changed();
  }
  bool restore_vectors(const Model &replacement, const std::string &next,
                       const std::string &next_cache, bool next_gpu) {
    if (next != path || next_cache != cache || next_gpu != use_gpu ||
        !state.active_generation())
      return false;
    Statement identity(
        db, "SELECT value FROM settings WHERE key='index_model_identity'");
    if (!identity.row() || identity.str(0) != model_identity(replacement))
      return false;
    Statement generation(db, "SELECT model_digest FROM vectors.generations "
                             "WHERE id=? AND status='active'");
    generation.num(1, state.active_generation());
    if (!generation.row() || generation.str(0) != replacement.digest)
      return false;
    Statement count(
        db, "SELECT COUNT(*) FROM documents d JOIN linux.source_revisions r ON "
            "r.id=d.id WHERE r.tombstone=0");
    count.row();
    state.set_attempted(count.integer(0));
    state.set_completed(count.integer(0));
    return true;
  }

public:
  Service(const std::string &root, bool allow,
          const foresight::schema::SourceSet &preflight)
      : allow_test(allow), storage_root(root) {
    try {
      preflight.verify_unchanged();
      if (sqlite3_open((root + "/agent_metadata.db").c_str(), &db) != SQLITE_OK)
        throw std::runtime_error("Cannot open metadata");
      sqlite3_busy_timeout(db, 5000);
      {
        Statement attach(db, "ATTACH DATABASE ? AS linux");
        attach.text(1, root + "/linux_state.db");
        attach.row();
      }
      {
        Statement attach(db, "ATTACH DATABASE ? AS vectors");
        attach.text(1, root + "/rag_vector.db");
        attach.row();
      }
      sql("PRAGMA main.journal_mode=DELETE; PRAGMA main.synchronous=FULL; "
          "PRAGMA main.secure_delete=ON; PRAGMA linux.journal_mode=DELETE; "
          "PRAGMA linux.synchronous=FULL; PRAGMA linux.secure_delete=ON; "
          "PRAGMA vectors.journal_mode=DELETE; PRAGMA "
          "vectors.synchronous=FULL; "
          "PRAGMA vectors.secure_delete=ON");
      foresight::schema::migrate_helpers(db);
      sql("INSERT OR IGNORE INTO linux.source_revisions SELECT id,1,0 FROM "
          "documents; DELETE FROM vectors.chunks WHERE NOT EXISTS (SELECT 1 "
          "FROM "
          "linux.source_revisions r WHERE r.id=chunks.document_id AND "
          "r.revision=chunks.revision AND r.tombstone=0); DELETE FROM "
          "vectors.chunks WHERE generation IN(SELECT id FROM "
          "vectors.generations "
          "WHERE status!='active'); DELETE FROM vectors.generations WHERE "
          "status!='active'");
      state.set_build_id(foresight_helper_build_id());
      state.set_reference_version(helperProtocolVersion);
      state.set_instance_id(
          std::to_string(getpid()) + "-" +
          std::to_string(
              std::chrono::system_clock::now().time_since_epoch().count()));
      state.set_pipeline("unconfigured");
      state.set_index("empty");
      state.set_revision(1);
      state.set_totals_known(true);
      Statement q(
          db, "SELECT value FROM settings WHERE key='embedding_model_path'");
      if (q.row())
        path = q.str(0);
      {
        Statement c(db, "SELECT value FROM settings WHERE key='cache_dir'");
        if (c.row())
          cache = c.str(0);
      }
      {
        Statement g(db, "SELECT value FROM settings WHERE key='use_gpu'");
        if (g.row())
          use_gpu = g.str(0) == "true";
      }
      Statement g(db,
                  "SELECT id FROM vectors.generations WHERE status='active'");
      if (g.row()) {
        state.set_active_generation(g.integer(0));
        state.set_index("degraded");
      }
      changed();
    } catch (...) {
      sqlite3_close(db);
      db = nullptr;
      throw;
    }
  }
  ~Service() {
    sqlite3_close(db);
  }
  Status Ping(grpc::ServerContext *, const rpc::PingRequest *,
              rpc::PingResponse *r) override {
    r->set_success(true);
    r->set_version(helperProtocolVersion);
    return Status::OK;
  }
  Status UpdateModelPaths(grpc::ServerContext *context,
                          const rpc::UpdateModelPathsRequest *req,
                          rpc::UpdateModelPathsResponse *r) override {
    ReconfigGuard guard(*this);
    try {
      if (auto status = guard.enter(context); !status.ok())
        return status;
      std::string next, next_cache;
      bool next_gpu = false;
      {
        std::lock_guard lock(mu);
        next = req->embedding_model_path().empty()
                   ? path
                   : req->embedding_model_path();
        next_cache = req->cache_dir().empty() ? cache : req->cache_dir();
        next_gpu =
            req->has_use_gpu()
                ? req->use_gpu()
                : (req->embedding_model_path().empty() ? use_gpu : false);
        if (!req->sentence_piece_model_path().empty())
          throw std::invalid_argument(
              "External SentencePiece unsupported: tokenizer is owned by the "
              "registered embedding model");
        if (context->IsCancelled())
          throw std::runtime_error("Model configuration cancelled");
        state.set_pipeline("loading");
        state.set_index("building");
        state.set_attempted(0);
        state.set_completed(0);
        state.set_failed(0);
        changed();
      }
      auto replacement = std::make_shared<Model>(next, allow_test, next_gpu);
      replacement->embed("readiness probe");
      if (context->IsCancelled())
        throw std::runtime_error("Model configuration cancelled");
      {
        std::lock_guard lock(mu);
        if (context->IsCancelled())
          throw std::runtime_error("Model configuration cancelled");
        if (restore_vectors(*replacement, next, next_cache, next_gpu)) {
          publish_model(replacement, next, next_cache, next_gpu,
                        state.active_generation());
          r->set_success(true);
          return Status::OK;
        }
      }
      std::vector<DocWork> docs;
      {
        std::lock_guard lock(mu);
        Statement rows(
            db, "SELECT "
                "d.id,d.content,d.maxTokensPerChunk,d.chunkOverlap,d.mimeType,"
                "r.revision FROM documents d JOIN linux.source_revisions r ON "
                "r.id=d.id WHERE r.tombstone=0");
        while (rows.row()) {
          DocWork doc;
          doc.id = rows.str(0);
          doc.content = rows.str(1);
          doc.size = rows.integer(2);
          doc.overlap = rows.integer(3);
          doc.mime = rows.str(4);
          doc.rev = rows.integer(5);
          docs.push_back(std::move(doc));
        }
      }
      for (auto &doc : docs) {
        if (context->IsCancelled())
          throw std::runtime_error("Model configuration cancelled");
        doc.chunks = prepare_chunks(*replacement, doc.content, doc.size,
                                    doc.overlap, doc.mime, context);
      }
      std::lock_guard lock(mu);
      if (context->IsCancelled())
        throw std::runtime_error("Model configuration cancelled");
      uint64_t gen = state.active_generation() + 1;
      state.set_pending_generation(gen);
      changed();
      Tx tx(*this);
      {
        Statement q(db,
                    "INSERT INTO vectors.generations VALUES(?,?,'building')");
        q.num(1, gen);
        q.text(2, replacement->digest);
        q.row();
      }
      for (auto &doc : docs) {
        state.set_attempted(state.attempted() + 1);
        insert_vectors(doc.chunks, doc.id, doc.rev, gen, doc.mime, context);
        state.set_completed(state.completed() + 1);
        changed();
      }
      sql("DELETE FROM vectors.chunks WHERE generation != " +
          std::to_string(gen));
      sql("DELETE FROM vectors.generations WHERE id != " + std::to_string(gen));
      sql("UPDATE vectors.generations SET status='active' WHERE id=" +
          std::to_string(gen));
      {
        Statement q(
            db,
            "INSERT OR REPLACE INTO settings VALUES('embedding_model_path',?)");
        q.text(1, next);
        q.row();
      }
      {
        Statement q(db,
                    "INSERT OR REPLACE INTO settings VALUES('cache_dir',?)");
        q.text(1, next_cache);
        q.row();
      }
      {
        Statement g(db, "INSERT OR REPLACE INTO settings VALUES('use_gpu',?)");
        g.text(1, next_gpu ? "true" : "false");
        g.row();
      }
      {
        Statement identity(
            db,
            "INSERT OR REPLACE INTO settings VALUES('index_model_identity',?)");
        identity.text(1, model_identity(*replacement));
        identity.row();
      }
      crash("model_before_commit");
      if (context->IsCancelled())
        throw std::runtime_error("Model configuration cancelled");
      tx.commit();
      publish_model(replacement, next, next_cache, next_gpu, gen);
      r->set_success(true);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      state.set_pending_generation(0);
      state.set_failed(state.failed() + 1);
      state.set_pipeline(model ? "ready" : "failed");
      state.set_index(model ? "degraded" : "failed");
      return app_error(r, e, context);
    }
  }
  Status IndexDocument(grpc::ServerContext *context,
                       const rpc::IndexRequest *req,
                       rpc::IndexResponse *r) override {
    ReconfigGuard guard(*this);
    try {
      if (auto status = guard.enter(context); !status.ok())
        return status;
      std::shared_ptr<Model> current;
      std::string id, content, user, mime, image;
      int size = 0, overlap = 0;
      {
        std::lock_guard lock(mu);
        if (context->IsCancelled())
          throw std::runtime_error("Index operation cancelled");
        if (!model)
          throw std::runtime_error("Pipeline not initialized");
        require_public_document(req->document_id());
        if (!req->image_bytes().empty() ||
            req->mime_type().starts_with("image/"))
          throw std::runtime_error(
              "Image embedding unavailable in text-only model");
        size =
            req->max_tokens_per_chunk() > 0 ? req->max_tokens_per_chunk() : 480;
        overlap = req->chunk_overlap() < 0 ? 5 : req->chunk_overlap();
        current = model;
        id = req->document_id();
        content = req->content();
        user = req->user_id();
        mime = req->mime_type();
        image = req->image_bytes();
      }
      auto prepared =
          prepare_chunks(*current, content, size, overlap, mime, context);
      std::lock_guard lock(mu);
      if (context->IsCancelled())
        throw std::runtime_error("Index operation cancelled");
      if (model != current)
        throw std::runtime_error("Embedding model changed; retry");
      std::vector<foresight::IndexedChunk> indexed;
      for (const auto &chunk : prepared)
        indexed.push_back({chunk.text, id, mime, chunk.embedding});
      // Allocate/build before committing. Publication after COMMIT is a
      // pointer swap, so successful writes are immediately searchable without
      // rereading unrelated SQLite rows or rebuilding the entire corpus.
      const auto children = transcript_ids(id);
      std::set<std::string> replaced(children.begin(), children.end());
      replaced.insert(id);
      auto replacement = stage_index(std::move(replaced), std::move(indexed));
      uint64_t rev = revision(id);
      Tx tx(*this);
      erase_transcript(id);
      {
        Statement q(db,
                    "INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?)");
        q.text(1, id);
        q.text(2, content);
        q.text(3, user);
        q.num(4, size);
        q.num(5, overlap);
        q.text(6, mime);
        if (image.empty())
          sqlite3_bind_null(q.p, 7);
        else
          q.blob(7, image);
        q.row();
      }
      {
        Statement q(
            db, "INSERT OR REPLACE INTO linux.source_revisions VALUES(?,?,0)");
        q.text(1, id);
        q.num(2, rev);
        q.row();
      }
      {
        Statement q(db, "DELETE FROM vectors.chunks WHERE document_id=?");
        q.text(1, id);
        q.row();
      }
      crash("metadata_written");
      insert_vectors(prepared, id, rev, state.active_generation(), mime,
                     context);
      crash("vectors_written");
      journal("replace", id, rev);
      crash("replace_before_commit");
      if (context->IsCancelled())
        throw std::runtime_error("Index operation cancelled");
      tx.commit();
      publish_snapshot(std::move(replacement));
      crash("replace_after_commit");
      state.set_index("ready");
      changed();
      r->set_success(true);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      return app_error(r, e, context);
    }
  }
  Status GetCursor(grpc::ServerContext *,
                   const transcript::TranscriptCursorRequest *req,
                   transcript::TranscriptCursor *result) override {
    std::lock_guard lock(mu);
    try {
      require_public_document(req->document_id());
      Statement q(
          db,
          "SELECT workspace_epoch,revision,last_segment_id,segment_count FROM "
          "linux.transcript_documents WHERE document_id=?");
      q.text(1, req->document_id());
      if (q.row()) {
        result->set_exists(true);
        result->set_workspace_epoch(q.str(0));
        result->set_revision(q.integer(1));
        result->set_last_segment_id(q.integer(2));
        result->set_segment_count(q.integer(3));
      }
      return Status::OK;
    } catch (const std::invalid_argument &e) {
      return {StatusCode::INVALID_ARGUMENT, e.what()};
    } catch (const std::exception &e) {
      return {StatusCode::FAILED_PRECONDITION, e.what()};
    }
  }
  Status ApplyDelta(grpc::ServerContext *context,
                    const transcript::TranscriptDelta *req,
                    transcript::TranscriptDeltaResult *result) override {
    ReconfigGuard guard(*this);
    try {
      if (auto status = guard.enter(context); !status.ok())
        return status;
      require_public_document(req->document_id());
      if (req->workspace_epoch().empty() ||
          req->workspace_epoch().size() > 128 || !req->revision() ||
          req->revision() > INT64_MAX || req->expected_revision() > INT64_MAX ||
          req->upserts_size() > 64 || req->deletes_size() > 64 ||
          req->ByteSizeLong() > 1024 * 1024)
        throw std::invalid_argument("Invalid bounded transcript delta");
      const auto delta = req->SerializeAsString();
      const auto &parent = req->document_id();
      const auto &epoch = req->workspace_epoch();
      std::shared_ptr<Model> current;
      struct Work {
        const transcript::TranscriptSegment *segment;
        std::string id;
        uint64_t revision;
        bool changed;
        std::vector<PreparedChunk> chunks;
      };
      uint64_t last_segment_id = 0, segment_count = 0;
      std::vector<Work> work;
      std::set<std::string> changed_ids;
      std::set<std::string> deleted;
      std::vector<foresight::IndexedChunk> indexed;
      {
        std::lock_guard lock(mu);
        if (!model)
          throw std::runtime_error("Pipeline not initialized");
        if (context->IsCancelled())
          throw std::runtime_error("Transcript indexing cancelled");
        current = model;
        uint64_t previous = 0;
        std::string previous_epoch;
        Statement q(db, "SELECT "
                        "workspace_epoch,revision,last_delta,last_segment_id,"
                        "segment_count FROM "
                        "linux.transcript_documents WHERE document_id=?");
        q.text(1, parent);
        if (q.row()) {
          previous_epoch = q.str(0);
          previous = q.integer(1);
          if (!req->reset()) {
            last_segment_id = q.integer(3);
            segment_count = q.integer(4);
          }
          if (previous == req->revision() && previous_epoch == epoch &&
              q.str(2) == delta) {
            result->set_revision(previous);
            result->set_applied(false);
            return Status::OK;
          }
        }
        if (previous != req->expected_revision() ||
            (!req->reset() && !previous_epoch.empty() &&
             previous_epoch != epoch) ||
            (!req->reset() && req->revision() <= previous))
          return {StatusCode::ABORTED,
                  "Transcript cursor changed; reconcile before retry"};
        if (req->reset()) {
          const auto old = transcript_ids(parent);
          changed_ids.insert(old.begin(), old.end());
          // Reset also replaces an older legacy full-transcript document.
          changed_ids.insert(parent);
        }
        std::set<std::string> supplied;
        auto checked_id = [&](const transcript::TranscriptKey &key) {
          if (!transcript::TranscriptKey_Channel_IsValid(key.channel()) ||
              !key.segment_id() || key.segment_id() > INT64_MAX)
            throw std::invalid_argument("Invalid transcript segment key");
          auto id = transcript_id(parent, epoch, key);
          if (!supplied.insert(id).second)
            throw std::invalid_argument("Duplicate transcript segment key");
          return id;
        };
        for (const auto &segment : req->upserts()) {
          if (!segment.has_key() || segment.text().empty() ||
              segment.text().size() > 65536 ||
              segment.end_ms() < segment.start_ms() ||
              segment.end_ms() > INT64_MAX)
            throw std::invalid_argument("Invalid bounded transcript segment");
          const auto id = checked_id(segment.key());
          Statement existing(db, "SELECT content FROM documents WHERE id=?");
          existing.text(1, id);
          const bool exists = existing.row();
          const bool changed =
              req->reset() || !exists || existing.str(0) != segment.text();
          if (req->reset() || !exists)
            ++segment_count;
          last_segment_id =
              std::max(last_segment_id, segment.key().segment_id());
          work.push_back({&segment, id, revision(id), changed, {}});
          if (changed)
            changed_ids.insert(id);
        }
        for (const auto &key : req->deletes()) {
          auto id = checked_id(key);
          if (!req->reset()) {
            Statement existing(
                db, "SELECT 1 FROM linux.transcript_segments WHERE id=?");
            existing.text(1, id);
            if (existing.row()) {
              if (!segment_count)
                throw std::runtime_error("Invalid transcript cursor count");
              --segment_count;
            }
          }
          last_segment_id = std::max(last_segment_id, key.segment_id());
          deleted.insert(id);
          changed_ids.insert(std::move(id));
        }
      }
      // Only bounded changed segments are tokenized/embedded. There is no
      // parent transcript concatenation, upsert or full scan on the append
      // path.
      for (auto &item : work) {
        if (!item.changed)
          continue;
        if (context->IsCancelled())
          throw std::runtime_error("Transcript indexing cancelled");
        size_t tokens = 0;
        const auto texts =
            current->chunks(item.segment->text(), 480, 0, &tokens);
        result->set_tokenized_bytes(result->tokenized_bytes() +
                                    item.segment->text().size());
        result->set_tokenized_tokens(result->tokenized_tokens() + tokens);
        for (const auto &text : texts) {
          auto vector = current->embed(text);
          result->set_embedded_bytes(result->embedded_bytes() + text.size());
          result->set_embedded_chunks(result->embedded_chunks() + 1);
          item.chunks.push_back({text, vector});
          indexed.push_back(
              {text, item.id, "text/plain", std::move(vector), false, parent});
        }
      }
      std::lock_guard lock(mu);
      if (context->IsCancelled())
        throw std::runtime_error("Transcript indexing cancelled");
      if (model != current)
        throw std::runtime_error("Embedding model changed; retry");
      auto replacement = stage_index(changed_ids, std::move(indexed));
      result->set_snapshot_constructed_chunks(
          changed_ids.empty() ? 0 : replacement->index.constructed_chunks());
      Tx tx(*this);
      if (req->reset()) {
        erase_transcript(parent);
        for (const auto *sqltext :
             {"DELETE FROM documents WHERE id=?",
              "DELETE FROM vectors.chunks WHERE document_id=?"}) {
          Statement q(db, sqltext);
          q.text(1, parent);
          q.row();
        }
      }
      for (const auto &id : deleted) {
        for (const auto *sqltext :
             {"DELETE FROM documents WHERE id=?",
              "DELETE FROM vectors.chunks WHERE document_id=?",
              "DELETE FROM linux.source_revisions WHERE id=?",
              "DELETE FROM linux.transcript_segments WHERE id=?",
              "DELETE FROM linux.journal WHERE document_id=?"}) {
          Statement q(db, sqltext);
          q.text(1, id);
          q.row();
        }
      }
      for (const auto &item : work) {
        const auto &segment = *item.segment;
        if (item.changed) {
          Statement q(db, "INSERT OR REPLACE INTO documents "
                          "VALUES(?,?,?,480,0,'text/plain',NULL)");
          q.text(1, item.id);
          q.text(2, segment.text());
          q.text(3, "local_user");
          q.row();
          Statement r(
              db,
              "INSERT OR REPLACE INTO linux.source_revisions VALUES(?,?,0)");
          r.text(1, item.id);
          r.num(2, item.revision);
          r.row();
          Statement old(db, "DELETE FROM vectors.chunks WHERE document_id=?");
          old.text(1, item.id);
          old.row();
          insert_vectors(item.chunks, item.id, item.revision,
                         state.active_generation(), "text/plain", context);
        }
        Statement q(db, "INSERT OR REPLACE INTO linux.transcript_segments "
                        "VALUES(?,?,?,?,?,?)");
        q.text(1, item.id);
        q.text(2, parent);
        q.num(3, segment.key().channel());
        q.num(4, segment.key().segment_id());
        q.num(5, segment.start_ms());
        q.num(6, segment.end_ms());
        q.row();
      }
      Statement cursor(db, "INSERT OR REPLACE INTO linux.transcript_documents "
                           "VALUES(?,?,?,?,?,?)");
      cursor.text(1, parent);
      cursor.text(2, epoch);
      cursor.num(3, req->revision());
      cursor.blob(4, delta);
      cursor.num(5, last_segment_id);
      cursor.num(6, segment_count);
      cursor.row();
      journal("transcript-delta", parent, req->revision());
      crash("transcript_before_commit");
      if (context->IsCancelled())
        throw std::runtime_error("Transcript indexing cancelled");
      tx.commit();
      publish_snapshot(std::move(replacement));
      crash("transcript_after_commit");
      state.set_index("ready");
      changed();
      result->set_revision(req->revision());
      result->set_applied(true);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      return app_error(result, e, context);
    }
  }
  Status DeleteDocument(grpc::ServerContext *context,
                        const rpc::DeleteRequest *req,
                        rpc::DeleteResponse *r) override {
    ReconfigGuard guard(*this);
    if (auto status = guard.enter(context); !status.ok())
      return status;
    std::lock_guard lock(mu);
    try {
      require_public_document(req->document_id());
      Tx tx(*this);
      std::vector<std::string> ids{req->document_id()};
      if (req->document_id().starts_with("file://"))
        ids.push_back(req->document_id().substr(7));
      else
        ids.push_back("file://" + req->document_id());
      std::set<std::string> replaced(ids.begin(), ids.end());
      for (const auto &id : ids) {
        const auto children = transcript_ids(id);
        replaced.insert(children.begin(), children.end());
      }
      auto replacement = stage_index(std::move(replaced), {});
      for (auto &id : ids) {
        erase_transcript(id);
        auto rev = revision(id);
        for (auto sqltext :
             {"DELETE FROM documents WHERE id=?",
              "DELETE FROM vectors.chunks WHERE document_id=?"}) {
          Statement q(db, sqltext);
          q.text(1, id);
          q.row();
        }
        Statement q(
            db, "INSERT OR REPLACE INTO linux.source_revisions VALUES(?,?,1)");
        q.text(1, id);
        q.num(2, rev);
        q.row();
        journal("delete", id, rev);
      }
      crash("delete_before_commit");
      tx.commit();
      publish_snapshot(std::move(replacement));
      crash("delete_after_commit");
      changed();
      r->set_success(true);
      return Status::OK;
    } catch (const std::exception &e) {
      return app_error(r, e, context);
    }
  }
  Status RetrieveContext(grpc::ServerContext *, const rpc::RetrieveRequest *req,
                         rpc::RetrieveResponse *r) override {
    if (!req->has_query() ||
        req->query().query_case() == rpc::Query::QUERY_NOT_SET)
      return {StatusCode::INVALID_ARGUMENT, "Query required"};
    if (req->max_results() <= 0)
      return {StatusCode::INVALID_ARGUMENT,
              "max_results must be positive (Linux policy)"};
    // Only copy shared ownership under this short pointer lock. Writers build
    // replacements and retire old trees outside it, without blocking searches.
    std::shared_ptr<const SearchSnapshot> snapshot;
    {
      std::lock_guard lock(snapshot_mu);
      snapshot = search_snapshot;
    }
    if (!snapshot || !snapshot->model || !snapshot->model->available()) {
      std::lock_guard lock(mu);
      return absent();
    }
    if (req->query().query_case() == rpc::Query::kAudioQuery)
      return {StatusCode::UNIMPLEMENTED,
              "Audio query unavailable in text-only model"};
    try {
      auto query = snapshot->model->embed(req->query().text_query(),
                                          EmbeddingTask::Query);
      std::set<std::string> allowed(req->allowed_document_ids().begin(),
                                    req->allowed_document_ids().end());
      for (auto match : snapshot->index.search(
               std::move(query), req->max_results(),
               static_cast<float>(req->min_similarity_score()), allowed)) {
        const auto &value = *match.chunk;
        auto *chunk = r->add_chunks();
        chunk->set_text(value.text);
        chunk->set_document_id(value.document_id());
        chunk->set_mime_type(value.mime);
        chunk->set_relevance_score(match.score);
      }
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      note_adapter_failure(snapshot->model, e);
      return {StatusCode::INTERNAL, e.what()};
    }
  }
  Status Encode(grpc::ServerContext *, const rpc::EncodeRequest *req,
                rpc::EncodeResponse *r) override {
    std::shared_ptr<Model> current;
    {
      std::lock_guard lock(mu);
      if (!model)
        return {StatusCode::UNAVAILABLE, "Tokenizer not initialized"};
      current = model;
    }
    try {
      auto tokens = current->encode(req->text());
      std::lock_guard lock(mu);
      for (int t : tokens)
        r->add_tokens(t);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      note_adapter_failure(current, e);
      return {StatusCode::INTERNAL, e.what()};
    }
  }
  Status ChunkText(grpc::ServerContext *, const rpc::ChunkTextRequest *req,
                   rpc::ChunkTextResponse *r) override {
    if (req->max_tokens_per_chunk() <= 0)
      return {StatusCode::INVALID_ARGUMENT,
              "Chunk size must be positive (Linux policy)"};
    std::shared_ptr<Model> current;
    {
      std::lock_guard lock(mu);
      if (!model)
        return {StatusCode::UNAVAILABLE, "Tokenizer not initialized"};
      current = model;
    }
    try {
      auto parts = current->chunks(req->text(), req->max_tokens_per_chunk(), 0);
      std::lock_guard lock(mu);
      for (auto &part : parts)
        r->add_chunks(part);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      note_adapter_failure(current, e);
      return {StatusCode::INTERNAL, e.what()};
    }
  }
  Status TruncateText(grpc::ServerContext *,
                      const rpc::TruncateTextRequest *req,
                      rpc::TruncateTextResponse *r) override {
    std::shared_ptr<Model> current;
    {
      std::lock_guard lock(mu);
      if (!model)
        return {StatusCode::UNAVAILABLE, "Tokenizer not initialized"};
      current = model;
    }
    try {
      auto tokens = current->encode(req->text());
      if (req->max_tokens() > 0 && size_t(req->max_tokens()) < tokens.size())
        tokens.resize(req->max_tokens());
      auto text = current->decode(tokens);
      std::lock_guard lock(mu);
      r->set_truncated_text(text);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      note_adapter_failure(current, e);
      return {StatusCode::INTERNAL, e.what()};
    }
  }
  Status ComputeEmbedding(grpc::ServerContext *,
                          const rpc::ComputeEmbeddingRequest *req,
                          rpc::ComputeEmbeddingResponse *r) override {
    std::shared_ptr<Model> current;
    {
      std::lock_guard lock(mu);
      if (!model || !model->available())
        return absent();
      current = model;
    }
    try {
      auto values = current->embed(req->text(), EmbeddingTask::Raw);
      std::lock_guard lock(mu);
      for (double x : values)
        r->add_embedding(x);
      return Status::OK;
    } catch (const std::exception &e) {
      std::lock_guard lock(mu);
      note_adapter_failure(current, e);
      return {StatusCode::INTERNAL, e.what()};
    }
  }
  Status ComputeImageEmbedding(grpc::ServerContext *,
                               const rpc::ComputeImageEmbeddingRequest *req,
                               rpc::ComputeEmbeddingResponse *) override {
    std::lock_guard lock(mu);
    if (!model || !model->available())
      return absent();
    if (req->image_bytes().empty())
      return {StatusCode::INVALID_ARGUMENT, "Image bytes empty"};
    return {StatusCode::UNIMPLEMENTED,
            "Image embedding unavailable in text-only model"};
  }
  Status ComputeAudioEmbedding(grpc::ServerContext *,
                               const rpc::ComputeAudioEmbeddingRequest *req,
                               rpc::ComputeEmbeddingResponse *) override {
    std::lock_guard lock(mu);
    if (!model || !model->available())
      return absent();
    if (req->audio_bytes().empty())
      return {StatusCode::INVALID_ARGUMENT, "Audio bytes empty"};
    return {StatusCode::UNIMPLEMENTED,
            "Audio embedding unavailable in text-only model"};
  }
  Status GetState(grpc::ServerContext *, const ctl::Empty *,
                  ctl::State *r) override {
    refresh_model_health();
    std::lock_guard lock(view_mu);
    *r = view;
    return Status::OK;
  }
  Status WatchState(grpc::ServerContext *context,
                    const ctl::WatchRequest *request,
                    grpc::ServerWriter<ctl::State> *writer) override {
    uint64_t last = request->last_revision();
    while (!context->IsCancelled()) {
      refresh_model_health();
      ctl::State snapshot;
      {
        std::lock_guard lock(view_mu);
        snapshot = view;
      }
      if (snapshot.revision() > last) {
        if (!writer->Write(snapshot))
          break;
        last = snapshot.revision();
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return Status::OK;
  }
};
int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc == 2 && std::string(argv[1]) == "--build-id") {
    std::cout << foresight_helper_build_id() << '\n';
    return 0;
  }
  int supervised = foresight::supervise_worker(argc, argv);
  if (supervised >= 0)
    return supervised;
  try {
    if (argc < 3) {
      std::cerr
          << "Usage: ForesightHelper SOCKET STORAGE [--allow-test-models]\n";
      return 2;
    }
    std::string socket = argv[1], root = argv[2];
    bool test = argc > 3 && std::string(argv[3]) == "--allow-test-models";
    umask(0077);
    bool new_root = !fs::exists(root);
    if (new_root)
      fs::create_directories(root);
    struct stat root_info{};
    if (stat(root.c_str(), &root_info) || root_info.st_uid != getuid() ||
        (root_info.st_mode & 0077))
      throw std::runtime_error(
          "Storage requires a private user-owned directory");
    const auto preflight = foresight::schema::qualify_helpers(root);
    int lock = open((root + "/.helper.lock").c_str(),
                    O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB))
      throw std::runtime_error("Another helper owns this storage root");
    fs::path parent = fs::path(socket).parent_path();
    if (parent.empty())
      throw std::runtime_error("Socket requires private parent directory");
    if (!fs::exists(parent))
      fs::create_directories(parent);
    struct stat info{};
    if (stat(parent.c_str(), &info) || info.st_uid != getuid() ||
        (info.st_mode & 0077))
      throw std::runtime_error(
          "Socket requires a private user-owned directory");
    if (fs::exists(socket)) {
      auto ch = grpc::CreateChannel("unix:" + socket,
                                    grpc::InsecureChannelCredentials());
      if (ch->WaitForConnected(std::chrono::system_clock::now() +
                               std::chrono::milliseconds(200)))
        throw std::runtime_error("Socket already serving");
      fs::remove(socket);
    }
    Service service(root, test, preflight);
    grpc::ServerBuilder b;
    b.AddListeningPort("unix:" + socket, grpc::InsecureServerCredentials());
    b.RegisterService(static_cast<rpc::RagService::Service *>(&service));
    b.RegisterService(static_cast<ctl::HelperControl::Service *>(&service));
    b.RegisterService(
        static_cast<transcript::TranscriptIndex::Service *>(&service));
    auto server = b.BuildAndStart();
    if (!server)
      throw std::runtime_error("Cannot listen on socket");
    chmod(socket.c_str(), 0600);
    std::cout << foresight_helper_build_id() << " ready " << socket
              << std::endl;
    server->Wait();
    close(lock);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
