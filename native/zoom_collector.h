#pragma once
// Bounded, passive collection of an accessibility tree into an AxSnapshot.
// The operating-system calls sit behind AxReader so the traversal rules
// (limits, absence versus failure, identity, cancellation) can be driven by a
// fake element tree.
#include "zoom_ax_parser.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace foresight::zoom {

// Opaque element handle. Valid until AxReader::end(); retain() extends that.
using ElementToken = uintptr_t;

// A missing attribute is an observed absence; any other failure leaves the
// snapshot incomplete. `Disabled` means the API reports accessibility off,
// which is a loss of trust, not a broken element.
enum class AttrStatus { Ok, Absent, Failed, Disabled };

struct TextAttr {
  AttrStatus status = AttrStatus::Absent;
  std::string text;
  // The platform string could not be represented faithfully (unencodable, or
  // cut at an embedded NUL).
  bool lossy = false;
};

struct NodeRead {
  AttrStatus call = AttrStatus::Ok; // the whole multi-attribute read
  TextAttr role, description, value, identifier;
  AttrStatus children_status = AttrStatus::Absent;
  std::vector<ElementToken> children;
  bool foreign_child = false; // an AXChildren entry was not an element
};

class AxReader {
public:
  virtual ~AxReader() = default;
  // Prepare to read one application. False when calls cannot be bounded by a
  // timeout (nothing is read then).
  virtual bool begin(int pid) = 0;
  // Windows of the application; Absent means it has none.
  virtual AttrStatus windows(std::vector<ElementToken> &out) = 0;
  virtual NodeRead read(ElementToken element) = 0;
  virtual void end() = 0;
  // Identity support: keep a token beyond end(), release it, and compare two.
  virtual ElementToken retain(ElementToken element) = 0;
  virtual void release(ElementToken element) = 0;
  virtual bool same(ElementToken a, ElementToken b) = 0;
};

// Stable ids for elements across reads. Entries unseen by the latest read are
// pruned once the table is half full; a full table yields id 0 (unknown).
class ElementRegistry {
public:
  explicit ElementRegistry(AxReader &reader, size_t capacity = 4096)
      : reader_(reader), capacity_(capacity) {}
  ~ElementRegistry();
  ElementRegistry(const ElementRegistry &) = delete;
  ElementRegistry &operator=(const ElementRegistry &) = delete;

  uint64_t identify(ElementToken element);
  void begin_read() {
    ++read_;
  }
  // Prunes unseen entries once the table is half full, but only after a read
  // that completed: an incomplete read did not see everyone, and forgetting
  // them would hand out new ids when they return.
  void end_read(bool read_completed = true);
  size_t size() const {
    return entries_.size();
  }

private:
  struct Entry {
    ElementToken element;
    uint64_t id;
    uint64_t seen;
  };
  AxReader &reader_;
  size_t capacity_;
  std::vector<Entry> entries_;
  uint64_t counter_ = 0;
  uint64_t read_ = 0;
};

struct CollectorLimits {
  int max_depth = kMaxDepth;
  size_t max_nodes = kMaxNodes;
  size_t max_string_bytes = 1024;
  std::chrono::milliseconds budget{1500};
};

struct CollectResult {
  AxSnapshot snapshot;
  bool trust_lost = false;
  bool cancelled = false;
  bool windows_failed = false;      // the window list itself could not be read
  bool identity_incomplete = false; // an element that needs an id has none
  size_t nodes = 0;
};

using SteadyNow = std::function<std::chrono::steady_clock::time_point()>;

// Reads every window of the begun application. The caller has already called
// reader.begin(); registry.begin_read()/end_read() bracket the call.
CollectResult collect_application(AxReader &reader, ElementRegistry &registry,
                                  const std::function<bool()> &cancelled,
                                  const CollectorLimits &limits = {},
                                  SteadyNow now = {});

} // namespace foresight::zoom
