#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1. Handles are owned, single caller controls lifecycle. Poll may run on
 * another thread. Each poll result is owned UTF-8 JSON, release with
 * string_free. Destroy cancels, joins workers and drains queues: no callbacks
 * after release. Poll may overlap destroy: destroy wakes and joins existing
 * polls, and a poll of a retired handle returns null. The lifecycle owner must
 * prevent new calls once destroy starts and finish every non-poll call before
 * destruction. Only polling may overlap destruction; cancellation can overlap
 * worker execution, and must return before destroy starts. Other API calls on
 * one handle are serialized by the caller. Handle addresses must not be reused
 * by a stale caller after release.
 * All status codes: 0 success, -1 invalid/busy/unavailable. No
 * fake inference. */
int fs_abi_version(void);
/* Before the first handle is created only (permanently sealed thereafter);
 * 0 success, -1 sealed/unsupported key/invalid value. Hosts must also avoid
 * external setenv/unsetenv while any native/runtime threads exist. */
int fs_set_runtime_environment(const char *key, const char *value);
/* 1 verified helper identity; 0 mismatch or confirmed absent; -1 inspection
 * unavailable (never evidence that shutdown succeeded). */
int fs_process_matches(int64_t pid, const char *socket, const char *storage,
                       const char *instance_id);
void fs_string_free(char *string);
char *fs_event_poll(void *handle, int timeout_ms);
void *fs_engine_create(const char *runtime_executable, const char *model_path);
/* Additive ABI v1: 0 llama.cpp CLI, 1 packaged LiteRT-LM CPU runner. */
void *fs_engine_create_backend(const char *runtime_executable,
                               const char *model_path, int backend);
/* Internal distribution model type selects recovered vision/audio startup. */
void *fs_engine_create_model_type(const char *runtime_executable,
                                  const char *model_path, int model_type);
char *fs_engine_state(void *engine);
/* Synchronous actual model load; no retained KV/model. The owned process group
 * is killed on FORESIGHT_PROBE_TIMEOUT_MS (default 120000 ms), and the engine
 * becomes available for another setup attempt. */
int fs_engine_probe(void *engine);
int fs_engine_destroy(
    void *engine); /* reject while probing/busy or conversations reference it */
void *fs_conversation_create(void *engine);
int fs_generate(void *conversation, const char *request_id, const char *prompt);
/* Additive ABI v1 extension: constrained JSON, same stream/lifetime rules. */
int fs_generate_json(void *conversation, const char *request_id,
                     const char *prompt, const char *json_schema);
int fs_generate_options(void *conversation, const char *request_id,
                        const char *prompt, const char *json_schema,
                        int max_output_tokens);
int fs_generation_cancel(void *conversation);
// Tool-enabled LiteRT conversation. Tool request/answer frames are polled as
// events. Replies are scoped to the active request and accepted once per batch.
// tools_json is {"tools":[...],"system_message":"..."}; a legacy array uses
// the runner's default system message. prompt is always user content.
// delegate_tool_detection=true emits model_response events. Reply with
// {"message":<user message>} to continue or {"finish":true} to accept the
// answer. An object with an empty tools array supports a plain local
// conversation.
int fs_generate_tools(void *conversation, const char *request_id,
                      const char *prompt, const char *tools_json,
                      int max_output_tokens);
int fs_generation_tool_reply(void *conversation, const char *request_id,
                             const char *message_json);
int fs_conversation_destroy(void *conversation, int cancel_and_drain);
void *fs_speech_create(const char *runtime_executable, const char *model_path);
int fs_speech_push(void *speech, const int16_t *samples, size_t count,
                   int sample_rate);
int fs_speech_finish(void *speech, const char *request_id);
int fs_speech_cancel(void *speech);
void fs_speech_destroy(void *speech);
/* target "auto" uses default device; playback sets stream.capture.sink=true.
 * PipeWire converts to mono signed 16-bit LE at sample_rate. Playback frames
 * contain floor(rate*40/1000)*2 bytes (3840 at 48kHz). Mic frames retain read
 * buffer sizes/even samples. Legacy channel map fields stay distinct;
 * state/error events use linux channel. */
void *fs_capture_start(const char *target, int playback, int sample_rate);
void *fs_capture_start_with_options(const char *target, int playback,
                                    int sample_rate, int echo_cancellation);
// Returns 1 if the native microphone route can accept the setting. Enabling on
// an existing standard engine takes effect on its next start; a processed
// engine changes bypass in place. Unsupported routes return 0 without changing
// capture.
int fs_capture_set_echo_cancellation(void *capture, int enabled);
/* Stops callbacks and flushes final PCM events, retaining handle for polling.
 * Call fs_capture_stop after draining to release the handle. */
void fs_capture_finish(void *capture);
void fs_capture_stop(void *capture);
/* Owned JSON string, release with fs_string_free. Discovery never prompts. */
char *fs_audio_capabilities(void);
/* Explicit setup only. Call off the service event loop; can wait for TCC UI. */
int fs_audio_request_microphone(void);
/* Explicit Core Audio consent request. Owned JSON, free with fs_string_free.
 * Waits for startup up to timeout_ms (clamped 0..30000). No PCM is inspected or
 * retained. Completion does not prove permission: inspect
 * permission_verified/code. */
char *fs_audio_request_system(int32_t timeout_ms);
/* Stateless utilities used by contract tests and import conversion. */
double fs_pcm_rms(const int16_t *samples, size_t count);
size_t fs_resample_pcm(const int16_t *input, size_t count, int input_rate,
                       int16_t *output, size_t capacity, int output_rate);
#ifdef __cplusplus
}
#endif
