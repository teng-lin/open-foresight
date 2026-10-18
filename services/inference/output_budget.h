#pragma once
#include <nlohmann/json.hpp>

namespace foresight {
// Zero preserves the native output default only for an explicit plain request.
inline bool valid_output_budget(const nlohmann::json &budget,
                                const nlohmann::json &definitions) {
  if (!budget.is_number_integer())
    return false;
  if (budget >= 1 && budget <= 3072)
    return true;
  return budget == 0 && definitions.is_object() &&
         definitions.contains("tools") && definitions["tools"].is_array() &&
         definitions["tools"].empty() &&
         definitions.value("use_default_output_limit", nlohmann::json(false)) ==
             true;
}
} // namespace foresight
