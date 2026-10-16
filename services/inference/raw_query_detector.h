#pragma once
#include "litert.h"

// Dedicated TextCache mode: empty base/context, raw input, CPU engine/context
// selected by the caller. No chat template, system text, tools or JSON schema.
inline std::string raw_query_detector(LiteRt &lm, LiteRtLmEngine *engine,
                                      const std::string &prompt) {
  auto config = handle(LM(session_config_create)(), LM(session_config_delete));
  LM(session_config_set_apply_prompt_template)(config.get(), false);
  LM(session_config_set_max_output_tokens)(config.get(), 512);
  auto sampler = handle(LM(sampler_params_create)(kLiteRtLmSamplerTypeTopP),
                        LM(sampler_params_delete));
  // LiteRT 0.18 rejects TOP_K at decode. k=1, p=1 retains the same one
  // candidate through its supported TOP_P implementation.
  LM(sampler_params_set_top_k)(sampler.get(), 1);
  LM(sampler_params_set_top_p)(sampler.get(), 1.0f);
  LM(sampler_params_set_temperature)(sampler.get(), 0.3f);
  LM(session_config_set_sampler_params)(config.get(), sampler.get());
  auto session = handle(LM(engine_create_session)(engine, config.get()),
                        LM(session_delete));
  // Original CTextCacheInput uses strlen on its UTF-8 strings.
  const auto size = prompt.find('\0');
  auto input = handle(LM(input_data_create)(kLiteRtLmInputDataTypeText,
                    prompt.data(), size == std::string::npos ? prompt.size() : size),
                    LM(input_data_delete));
  const LiteRtLmInputData *inputs[] = {input.get()};
  if (LM(session_run_prefill)(session.get(), inputs, 1) != 0)
    throw std::runtime_error("Raw detector prefill failed");
  auto response = handle(LM(session_run_decode)(session.get()), LM(responses_delete));
  if (LM(responses_get_num_candidates)(response.get()) < 1)
    throw std::runtime_error("Raw detector returned no candidates");
  const auto text = LM(responses_get_response_text_at)(response.get(), 0);
  if (!text) throw std::runtime_error("Raw detector returned a null candidate");
  return text;
}
