#pragma once
// Meeting-local participant references for one window.
//
// A reference follows a person as far as the source can tell. With an element
// identity the reference is keyed by (element, comparison key): an element that
// is reused for someone else, or renamed, gets a new reference, so a screen
// slot never lends one person's reference to another. Without element identity
// the reference is keyed by name and ordinal and only trusted while the count
// of that name is unchanged; duplicate names there cannot be told apart across
// polls, which the result reports so the observation can be marked incomplete.
#include "zoom_ax_parser.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace foresight::zoom {

class RefTable {
public:
  struct Result {
    std::vector<std::string> refs;
    // References could not all be remembered (capacity) or continuity cannot be
    // promised (duplicate names without element identity).
    bool uncertain = false;
  };

  explicit RefTable(size_t capacity = 4096) : capacity_(capacity) {}

  Result assign(const std::string &window,
                const std::vector<Participant> &participants) {
    if (window != window_) {
      window_ = window;
      by_object_.clear();
      by_name_.clear();
    }
    ++generation_;
    std::map<std::string, int> totals;
    for (const auto &participant : participants)
      ++totals[participant.key];
    std::map<std::string, int> ordinals;
    Result result;
    result.refs.assign(participants.size(), std::string());
    struct Pending {
      size_t index;
      std::pair<uint64_t, std::string> object_key;
      std::pair<std::string, int> name_key;
      int count;
    };
    std::vector<Pending> pending;
    // Pass 1: everyone already known keeps their reference and is marked as
    // present, so nothing below can evict a person who is still here.
    for (size_t i = 0; i < participants.size(); ++i) {
      const auto &participant = participants[i];
      int total = totals[participant.key];
      // Equal names cannot be told apart if their tiles trade places (with
      // element identity) or come and go (without it): never certain.
      if (total > 1)
        result.uncertain = true;
      if (participant.object_id != 0) {
        auto key = std::make_pair(participant.object_id, participant.key);
        auto it = by_object_.find(key);
        if (it != by_object_.end()) {
          it->second.touched = generation_;
          result.refs[i] = it->second.ref;
        } else {
          pending.push_back({i, key, {}, 0});
        }
      } else {
        auto key = std::make_pair(participant.key, ordinals[participant.key]++);
        auto it = by_name_.find(key);
        // The set of people sharing this name changed: do not hand an old
        // reference to whoever now holds the slot.
        if (it != by_name_.end() && it->second.count == total) {
          it->second.touched = generation_;
          result.refs[i] = it->second.ref;
        } else {
          pending.push_back({i, {}, key, total});
        }
      }
    }
    // Pass 2: make room by forgetting people who are not in this observation,
    // then allocate for the newcomers.
    if (entries() + pending.size() > capacity_) {
      size_t before = entries();
      for (auto it = by_object_.begin(); it != by_object_.end();)
        it = it->second.touched == generation_ ? std::next(it)
                                               : by_object_.erase(it);
      for (auto it = by_name_.begin(); it != by_name_.end();)
        it = it->second.touched == generation_ ? std::next(it)
                                               : by_name_.erase(it);
      if (entries() < before)
        result.uncertain =
            true; // those people get new references if they return
    }
    for (const auto &item : pending) {
      std::string ref = next();
      bool object = participants[item.index].object_id != 0;
      bool replaces = !object && by_name_.count(item.name_key) != 0;
      if (replaces || entries() < capacity_) {
        if (object)
          by_object_[item.object_key] = {ref, generation_, 0};
        else
          by_name_[item.name_key] = {ref, generation_, item.count};
      } else {
        result.uncertain = true; // untracked: nobody remembers this reference
      }
      result.refs[item.index] = std::move(ref);
    }
    return result;
  }

  size_t entries() const {
    return by_object_.size() + by_name_.size();
  }

private:
  struct Entry {
    std::string ref;
    uint64_t touched = 0;
    int count = 0;
  };

  std::string next() {
    return "p" + std::to_string(++counter_);
  }

  size_t capacity_;
  std::string window_;
  uint64_t counter_ = 0;
  uint64_t generation_ = 0;
  std::map<std::pair<uint64_t, std::string>, Entry> by_object_;
  std::map<std::pair<std::string, int>, Entry> by_name_;
};

} // namespace foresight::zoom
