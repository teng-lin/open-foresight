#pragma once
// Open Foresight's source-built extension to pinned LiteRT-LM 0.18.0.
// See ../stop-token-sequences.patch. No private ABI or opaque layout access.
#include "engine.h"
#ifdef __cplusplus
extern "C" {
#endif
LITERT_LM_C_API_EXPORT
int litert_lm_session_config_add_stop_token_sequence(
    LiteRtLmSessionConfig *config, const int32_t *token_ids, size_t count);
#ifdef __cplusplus
}
#endif
