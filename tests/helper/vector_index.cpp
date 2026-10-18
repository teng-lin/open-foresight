#include "vector_index.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <map>
#include <random>
#include <thread>
#define REQUIRE(condition)                                                     \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::cerr << __FILE__ << ":" << __LINE__ << ": " << #condition << "\n";  \
      std::exit(1);                                                            \
    }                                                                          \
  } while (false)

int main(int argc, char **argv) {
  // CTest expects this invocation to fail, including Release/NDEBUG builds.
  if (argc == 2 && std::string(argv[1]) == "--require-failure")
    REQUIRE(false);
  using namespace foresight;
  std::mt19937 rng(71);
  std::normal_distribution<double> random;
  std::vector<IndexedChunk> chunks;
  for (int i = 0; i < 300; ++i) {
    std::vector<double> vector;
    for (int j = 0; j < 12; ++j)
      vector.push_back(random(rng));
    REQUIRE(read_vector(vector_blob(vector)) == vector);
    chunks.push_back(
        {std::to_string(i), std::to_string(i % 7), "text/plain", vector});
  }
  VectorIndex index(chunks);
  for (int test = 0; test < 80; ++test) {
    std::vector<double> query;
    for (int j = 0; j < 12; ++j)
      query.push_back(random(rng));
    auto actual = index.search(query, 5, -.2, {"1", "4"});
    double norm = 0;
    for (double x : query)
      norm += x * x;
    for (double &x : query)
      x /= sqrt(norm);
    std::vector<VectorIndex::Match> expected;
    for (size_t i = 0; i < index.chunks.size(); ++i) {
      auto &chunk = index.chunks[i];
      if (chunk.id != "1" && chunk.id != "4")
        continue;
      double score = 0;
      for (int j = 0; j < 12; ++j)
        score += query[j] * chunk.vector[j];
      if (score >= -.2)
        expected.push_back({score, i});
    }
    std::sort(expected.begin(), expected.end(), [](auto a, auto b) {
      return a.score != b.score ? a.score > b.score : a.chunk < b.chunk;
    });
    expected.resize(std::min(size_t(5), expected.size()));
    REQUIRE(actual.size() == expected.size());
    for (size_t i = 0; i < actual.size(); ++i)
      REQUIRE(actual[i].chunk == expected[i].chunk);
  }
  bool rejected = false;
  try {
    read_vector("FSV1x");
  } catch (...) {
    rejected = true;
  }
  REQUIRE(rejected);
  VectorIndex zero({{"zero", "0", "", {0, 0}}, {"unit", "1", "", {1, 0}}});
  REQUIRE(zero.search({0, 0}, 2, 0).size() == 2);
  VectorIndex mixed({{"first", "0", "", {1, 0}},
                     {"zero", "1", "", {0, 0}},
                     {"orthogonal", "2", "", {0, 1}}});
  REQUIRE(mixed.search({0, 0}, 1, 0).front().chunk == 0);
  auto ties = mixed.search({0, 1}, 2, 0);
  REQUIRE(ties.size() == 2 && ties[0].chunk == 2 && ties[1].chunk == 0);

  // Compare every update against a fresh exact index. Replacements of varying
  // sizes, empty documents, tombstones and reinsertion must suppress old top
  // hits before pruning, including allowed-ID filters and zero-vector ties.
  VectorIndexSnapshot snapshot;
  std::map<std::string, std::vector<IndexedChunk>> documents;
  for (int update = 0; update < 180; ++update) {
    const std::string id = std::to_string(update % 13);
    std::vector<IndexedChunk> replacement;
    if (update % 5 != 0)
      for (int ordinal = 0; ordinal < update % 4 + 1; ++ordinal)
        replacement.push_back(
            {std::to_string(update) + ":" + std::to_string(ordinal), id,
             "text/plain",
             update % 3 == 0
                 ? std::vector<double>{0, 0}
                 : std::vector<double>{double(update % 7), double(ordinal)}});
    documents[id] = replacement;
    snapshot = snapshot.replacing({id}, replacement);
    std::vector<IndexedChunk> live;
    for (const auto &[key, values] : documents)
      live.insert(live.end(), values.begin(), values.end());
    REQUIRE(snapshot.live_chunk_count() == live.size());
    REQUIRE(snapshot.retained_chunk_count() >= live.size());
    VectorIndex expected(live);
    for (const auto &query :
         {std::vector<double>{0, 0}, std::vector<double>{1, 0},
          std::vector<double>{1, 2}}) {
      for (const auto &allowed :
           {std::set<std::string>{}, std::set<std::string>{"0", "2", "7"}}) {
        for (double minimum : {-.5, 0., .7}) {
          for (size_t limit : {size_t(0), size_t(1), size_t(7), size_t(100)}) {
            auto actual = snapshot.search(query, limit, minimum, allowed);
            auto reference = expected.search(query, limit, minimum, allowed);
            REQUIRE(actual.size() == reference.size());
            for (size_t i = 0; i < actual.size(); ++i) {
              const auto &wanted = expected.chunks[reference[i].chunk];
              REQUIRE(actual[i].chunk->id == wanted.id);
              REQUIRE(actual[i].chunk->text == wanted.text);
              REQUIRE(actual[i].score == reference[i].score);
            }
          }
        }
      }
    }
  }

  std::vector<IndexedChunk> base;
  for (int i = 0; i < 4096; ++i)
    base.push_back({"original", "base-" + std::to_string(i), "", {1, 0}});
  VectorIndexSnapshot old(base);
  auto updated = old;
  std::atomic<bool> stop = false;
  std::atomic<size_t> reads = 0;
  std::thread reader([&] {
    while (!stop) {
      auto found = old.search({1, 0}, 1, .9, {"base-0"});
      REQUIRE(found.size() == 1 && found[0].chunk->text == "original");
      ++reads;
    }
  });
  while (!reads)
    std::this_thread::yield();
  size_t construction = 0;
  for (int i = 0; i < 128; ++i) {
    auto id = "base-" + std::to_string(i);
    updated = updated.replacing({id}, {{"new", id, "", {0, 1}}});
    construction += updated.constructed_chunks();
    auto visible = updated.search({0, 1}, 1, .9, {id});
    REQUIRE(visible.size() == 1 && visible[0].chunk->text == "new");
    REQUIRE(updated.search({1, 0}, 1, .9, {id}).empty());
    REQUIRE(updated.segment_count() <= 9);
    while (reads <= size_t(i + 1))
      std::this_thread::yield();
  }
  stop = true;
  reader.join();
  // A full 4096-chunk rebuild after each write would cost >500k here. Bound
  // amortized work without depending on a particular compaction schedule.
  REQUIRE(construction <= 128 * 8);
  REQUIRE(old.search({1, 0}, 4096, .9).size() == 4096);
  REQUIRE(updated.search({1, 0}, 4096, .9).size() == 4096 - 128);
  // A single large document can cross several weight classes at once; it
  // compacts the base exactly once, then tiny replacements/deletes hide all of
  // its old high-scoring chunks before the per-segment top-k is selected.
  std::vector<IndexedChunk> oversized;
  for (int i = 0; i < 10000; ++i)
    oversized.push_back({std::to_string(i), "oversized", "", {0, 1}});
  auto large = updated.replacing({"oversized"}, std::move(oversized));
  REQUIRE(large.segment_count() == 1);
  REQUIRE(large.constructed_chunks() == 14096);
  auto first = large.search({0, 1}, 5, .9, {"oversized"});
  REQUIRE(first.size() == 5);
  for (size_t i = 0; i < first.size(); ++i)
    REQUIRE(first[i].chunk->text == std::to_string(i));
  auto tiny =
      large.replacing({"oversized"}, {{"tiny", "oversized", "", {1, 0}}});
  REQUIRE(tiny.search({0, 1}, 5, .9, {"oversized"}).empty());
  REQUIRE(tiny.search({1, 0}, 5, .9, {"oversized"}).front().chunk->text ==
          "tiny");
  auto removed = tiny.replacing({"oversized"}, {});
  REQUIRE(removed.search({1, 0}, 5, 0, {"oversized"}).empty());
  auto reinserted =
      removed.replacing({"oversized"}, {{"zero", "oversized", "", {0, 0}}});
  REQUIRE(reinserted.search({0, 0}, 5, 0, {"oversized"}).front().chunk->text ==
          "zero");
  // Tombstones are small writes but can hide many chunks. Repeated deletions
  // must release obsolete trees rather than leave an empty corpus traversing
  // every historical vector forever. Keep old reader snapshots unchanged.
  std::vector<IndexedChunk> multichunk;
  for (int doc = 0; doc < 256; ++doc)
    for (int ordinal = 0; ordinal < 16; ++ordinal)
      multichunk.push_back(
          {std::to_string(ordinal), "doc-" + std::to_string(doc), "", {1, 0}});
  VectorIndexSnapshot before_deletes(multichunk);
  auto deleting = before_deletes;
  for (int doc = 0; doc < 256; ++doc) {
    auto id = "doc-" + std::to_string(doc);
    deleting = deleting.replacing({id, "file://" + id}, {});
    REQUIRE(deleting.live_chunk_count() == size_t(255 - doc) * 16);
    REQUIRE(deleting.retained_chunk_count() <=
            std::max(size_t(1024), 2 * deleting.live_chunk_count()));
    REQUIRE(deleting.search({1, 0}, 16, .9, {id}).empty());
    if (doc != 255) {
      auto remaining_id = "doc-" + std::to_string(doc + 1);
      auto matches = deleting.search({1, 0}, 16, .9, {remaining_id});
      REQUIRE(matches.size() == 16);
      for (size_t i = 0; i < matches.size(); ++i)
        REQUIRE(matches[i].chunk->text == std::to_string(i));
    }
  }
  REQUIRE(deleting.segment_count() == 0);
  REQUIRE(deleting.retained_chunk_count() == 0);
  REQUIRE(deleting.search({1, 0}, 1, .9).empty());
  REQUIRE(before_deletes.search({1, 0}, 4096, .9).size() == 4096);
  deleting = deleting.replacing({"doc-0"}, {{"new", "doc-0", "", {0, 1}}});
  REQUIRE(deleting.live_chunk_count() == 1);
  REQUIRE(deleting.retained_chunk_count() == 1);
  REQUIRE(deleting.search({0, 1}, 1, .9).front().chunk->text == "new");
  REQUIRE(tiny.retained_chunk_count() == tiny.live_chunk_count());
  // Switching embedding generations creates an independent forest: no old
  // dimension, document revision or tombstone can enter the replacement.
  VectorIndexSnapshot generation({{"fresh", "base-0", "", {0, 0, 1}}});
  REQUIRE(generation.search({0, 0, 1}, 5, .9).size() == 1);
  REQUIRE(old.search({1, 0}, 1, .9).size() == 1);
  std::cout << "binary serialization and exact indexed filtered top-k passed\n";
}
