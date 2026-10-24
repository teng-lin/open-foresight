#ifndef FORESIGHT_HELPER_SCHEMA_MIGRATIONS_H
#define FORESIGHT_HELPER_SCHEMA_MIGRATIONS_H

#include "schema_preflight.h"
#include "vector_index.h"
#include <nlohmann/json.hpp>
#include <sqlite3.h>
#include <stdexcept>
#include <string>
#include <vector>

namespace foresight::schema {
inline void execute(sqlite3 *db, const std::string &sql) {
  char *error = nullptr;
  if (sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &error) != SQLITE_OK) {
    const std::string message =
        error ? error : "SQLite schema migration failed";
    sqlite3_free(error);
    throw std::runtime_error(message);
  }
}
class MigrationStatement {
  sqlite3_stmt *statement_ = nullptr;

public:
  MigrationStatement(sqlite3 *db, const char *sql) {
    if (sqlite3_prepare_v2(db, sql, -1, &statement_, nullptr) != SQLITE_OK)
      throw std::runtime_error(sqlite3_errmsg(db));
  }
  ~MigrationStatement() {
    sqlite3_finalize(statement_);
  }
  sqlite3_stmt *get() const {
    return statement_;
  }
  bool row() {
    const int rc = sqlite3_step(statement_);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE)
      throw std::runtime_error(sqlite3_errmsg(sqlite3_db_handle(statement_)));
    return rc == SQLITE_ROW;
  }
};
inline int version(sqlite3 *db, const std::string &name) {
  MigrationStatement query(db, ("PRAGMA " + name + ".user_version").c_str());
  if (!query.row())
    throw std::runtime_error("Cannot read helper schema version");
  return sqlite3_column_int(query.get(), 0);
}

/// All three rollback-journal members share SQLite's attached transaction.
/// Schema1 freezes the legacy DDL and JSON→binary vector conversion; ordinary
/// startup pruning remains a separate runtime policy after this commits.
inline void migrate_helpers(sqlite3 *db) {
  execute(db, "BEGIN IMMEDIATE");
  try {
    const int main = version(db, "main"), linux = version(db, "linux"),
              vectors = version(db, "vectors");
    for (const int value : {main, linux, vectors}) {
      if (value < 0 || value > helper_version)
        throw std::runtime_error("Unsupported newer helper database version");
    }
    if (main == helper_version && linux == helper_version &&
        vectors == helper_version) {
      execute(db, "COMMIT");
      return;
    }
    if (main < 1 || linux < 1 || vectors < 1) {
      if (main == 0)
        execute(
            db,
            "CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,content "
            "TEXT,userId TEXT,maxTokensPerChunk INTEGER,chunkOverlap "
            "INTEGER,mimeType TEXT,imageBytes BLOB); CREATE TABLE IF NOT "
            "EXISTS "
            "settings(key TEXT PRIMARY KEY,value TEXT)");
      if (linux == 0)
        execute(
            db,
            "CREATE TABLE IF NOT EXISTS linux.source_revisions(id TEXT PRIMARY "
            "KEY,revision INTEGER NOT NULL,tombstone INTEGER NOT NULL); CREATE "
            "TABLE IF NOT EXISTS linux.journal(sequence INTEGER PRIMARY "
            "KEY,operation TEXT,document_id TEXT,revision INTEGER,generation "
            "INTEGER,status TEXT)");
      if (vectors == 0) {
        execute(
            db,
            "CREATE TABLE IF NOT EXISTS vectors.chunks(generation "
            "INTEGER,document_id TEXT,revision INTEGER,ordinal INTEGER,text "
            "TEXT,mime TEXT,embedding BLOB,PRIMARY "
            "KEY(generation,document_id,revision,ordinal)); CREATE TABLE IF "
            "NOT "
            "EXISTS vectors.generations(id INTEGER PRIMARY KEY,model_digest "
            "TEXT,status TEXT)");
        MigrationStatement rows(db,
                                "SELECT rowid,embedding FROM vectors.chunks "
                                "WHERE typeof(embedding)='text'");
        while (rows.row()) {
          const auto *text = sqlite3_column_text(rows.get(), 1);
          const int length = sqlite3_column_bytes(rows.get(), 1);
          const auto bytes =
              foresight::vector_blob(nlohmann::json::parse(text, text + length)
                                         .get<std::vector<double>>());
          MigrationStatement update(
              db, "UPDATE vectors.chunks SET embedding=? WHERE rowid=?");
          sqlite3_bind_blob(update.get(), 1, bytes.data(), bytes.size(),
                            SQLITE_TRANSIENT);
          sqlite3_bind_int64(update.get(), 2,
                             sqlite3_column_int64(rows.get(), 0));
          update.row();
        }
      }
      execute(db, "PRAGMA main.user_version=1; PRAGMA linux.user_version=1; "
                  "PRAGMA vectors.user_version=1");
    }
    if (linux < 2) {
      execute(db,
              "CREATE TABLE linux.transcript_documents(document_id TEXT "
              "PRIMARY KEY,"
              "workspace_epoch TEXT NOT NULL,revision INTEGER NOT "
              "NULL,last_delta BLOB NOT NULL,last_segment_id INTEGER NOT NULL,"
              "segment_count INTEGER NOT NULL);"
              "CREATE TABLE linux.transcript_segments(id TEXT PRIMARY "
              "KEY,parent_id TEXT NOT NULL,"
              "channel INTEGER NOT NULL,segment_id INTEGER NOT NULL,start_ms "
              "INTEGER NOT NULL,"
              "end_ms INTEGER NOT NULL,UNIQUE(parent_id,channel,segment_id));"
              "CREATE INDEX linux.transcript_parent ON "
              "transcript_segments(parent_id)");
    }
    // Losing authoritative derived metadata must invalidate the old cursor;
    // the application then replays its committed segments into a fresh index.
    if (main == 0 && linux > 0)
      execute(db, "DELETE FROM linux.transcript_documents; DELETE FROM "
                  "linux.transcript_segments");
    if (linux == 0 && (main >= 2 || vectors >= 2)) {
      // The parent/citation mapping is derived but essential. Never expose
      // orphan internal IDs after losing that member. Preserve legacy document
      // bodies and force a fresh vector generation before readiness.
      execute(db,
              "DELETE FROM vectors.chunks WHERE substr(CAST(document_id AS "
              "BLOB),1,1)=X'00';"
              "DELETE FROM documents WHERE substr(CAST(id AS BLOB),1,1)=X'00';"
              "DELETE FROM settings WHERE key='index_model_identity'");
    }
    execute(db, "PRAGMA main.user_version=2; PRAGMA linux.user_version=2; "
                "PRAGMA vectors.user_version=2");
    execute(db, "COMMIT");
  } catch (...) {
    if (!sqlite3_get_autocommit(db))
      sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr);
    throw;
  }
}
} // namespace foresight::schema
#endif
