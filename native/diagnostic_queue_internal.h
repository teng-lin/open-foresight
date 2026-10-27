#pragma once

#include "diagnostic_queue.h"

namespace foresight::diagnostics {
enum class Level : uint8_t { off, error, warn, info, debug, trace };
/* Called only while installing the runtime's sealed configuration, before
 * native handles start. The integration owns seal/replay validation. */
__attribute__((visibility("hidden"))) void configure(Level level) noexcept;
/* These trusted producers choose the registered event, component and priority.
 * Invalid closed enums or irrelevant fields are rejected before queue access.
 * false means filtered/rejected/dropped; logging never changes business work.
 */
__attribute__((visibility("hidden"))) bool
worker_failed(uint16_t category, uint16_t outcome, int32_t status,
              int32_t signal, uint64_t bytes = 0,
              uint64_t dropped = 0) noexcept;
__attribute__((visibility("hidden"))) bool
capture_state(uint16_t category, uint16_t outcome, uint32_t queued, bool active,
              uint64_t duration_us = 0) noexcept;
} // namespace foresight::diagnostics
