#include "../../native/owned_operations.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <new>

namespace {
std::atomic<bool> fail_allocations{false};
struct Failure final : std::exception {
  const char *what() const noexcept override {
    return "owned operation failed";
  }
};
void require(bool value, const char *message) {
  if (!value) {
    std::cerr << message << '\n';
    std::abort();
  }
}
template <class Predicate> void eventually(Predicate ready) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (!ready() && std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  require(ready(), "owned native work did not settle");
}
struct Gate {
  std::atomic<bool> entered{false}, release{false}, destroyed{false};
};
struct Lease {
  Gate &gate;
  explicit Lease(Gate &value) : gate(value) {}
  ~Lease() {
    gate.destroyed.store(true, std::memory_order_release);
  }
};
foresight::OwnedOperation::Result held(foresight::OwnedOperation &operation) {
  auto &gate = static_cast<Lease *>(operation.context)->gate;
  gate.entered.store(true, std::memory_order_release);
  while (!gate.release.load(std::memory_order_acquire))
    std::this_thread::yield();
  return foresight::OwnedOperation::Result::succeeded;
}
foresight::OwnedOperation::Result throws(foresight::OwnedOperation &) {
  throw Failure{};
}
foresight::OwnedOperation::Result failed(foresight::OwnedOperation &) {
  return foresight::OwnedOperation::Result::failed;
}
} // namespace

void *operator new(std::size_t size) {
  if (fail_allocations.load(std::memory_order_relaxed))
    throw std::bad_alloc{};
  if (void *value = std::malloc(size ? size : 1))
    return value;
  throw std::bad_alloc{};
}
void operator delete(void *value) noexcept {
  std::free(value);
}
void operator delete(void *value, std::size_t) noexcept {
  std::free(value);
}

int main() {
  {
    foresight::OwnedOperations bounded(2);
    auto first = bounded.create(failed, nullptr);
    auto second = bounded.create(failed, nullptr);
    bool refused = false;
    try {
      (void)bounded.create(failed, nullptr);
    } catch (const std::length_error &) {
      refused = true;
    }
    require(refused, "unacknowledged metadata grew beyond its fixed capacity");
    require(bounded.discard(first), "unpublished capacity rollback failed");
    auto replacement = bounded.create(failed, nullptr);
    require(replacement->token > second->token,
            "capacity reuse must not recycle a completion identity");
    require(bounded.discard(second) && bounded.discard(replacement),
            "bounded unpublished cleanup failed");
  }
  foresight::OwnedOperations operations;
  Gate gate;
  auto resource = std::make_shared<Lease>(gate);
  auto operation = operations.create(held, resource.get());
  const auto token = operation->token;
  require(operations.status(token) == 0, "new token must be pending");
  require(!operations.release(token), "pending token released its owner");
  // Submission/status/completion/release need no new allocation, even while the
  // original caller drops every local resource/operation reference.
  fail_allocations.store(true);
  require(operations.submit(operation, resource), "submission was refused");
  require(!operations.submit(operation, resource), "submitted twice");
  resource.reset();
  operation.reset();
  eventually([&] { return gate.entered.load(std::memory_order_acquire); });
  require(operations.status(token) == 0, "held operation falsely completed");
  require(!gate.destroyed.load(std::memory_order_acquire),
          "lease destroyed before native work settled");
  require(!operations.release(token), "held token released its owner");
  gate.release.store(true, std::memory_order_release);
  eventually([&] { return operations.status(token) == 1; });
  require(gate.destroyed.load(std::memory_order_acquire),
          "completion preceded actual lease destruction");
  require(operations.status(token) == 1,
          "completion lost when original acknowledgement was lost");
  require(operations.release(token), "completed token could not release");
  require(operations.status(token) == -1 && !operations.release(token),
          "released token resurrected");
  fail_allocations.store(false);

  Gate known_failure;
  auto failure_resource = std::make_shared<Lease>(known_failure);
  auto failure = operations.create(failed, failure_resource.get());
  require(operations.submit(failure, failure_resource), "failure submit");
  failure_resource.reset();
  failure->wait();
  require(operations.status(failure->token) == 2 &&
              known_failure.destroyed.load(std::memory_order_acquire),
          "known error must settle ownership before completion");
  require(operations.release(failure->token), "known error token release");

  auto idle = operations.create(failed, nullptr);
  require(operations.discard(idle) && operations.status(idle->token) == -1,
          "unpublished rollback retained its token");

  Gate unconfirmed;
  {
    foresight::OwnedOperations isolated;
    auto held_resource = std::make_shared<Lease>(unconfirmed);
    auto unexpected = isolated.create(throws, held_resource.get());
    auto &reporter = foresight::barrier_error_state();
    reporter.busy.test_and_set(std::memory_order_acquire);
    fail_allocations.store(true);
    require(isolated.submit(unexpected, held_resource), "exception submit");
    held_resource.reset();
    eventually([&] {
      return unexpected->boundary_failed.load(std::memory_order_acquire) &&
             isolated.status(unexpected->token) == 3;
    });
    fail_allocations.store(false);
    reporter.busy.clear(std::memory_order_release);
    require(isolated.status(unexpected->token) == 3 &&
                !isolated.release(unexpected->token) &&
                !unconfirmed.destroyed.load(std::memory_order_acquire),
            "secondary exception falsely acknowledged cleanup");
  }
  require(unconfirmed.destroyed.load(std::memory_order_acquire),
          "executor registry did not retain/release its final owner");
  return 0;
}
