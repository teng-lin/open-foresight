#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1. Handles are owned, single caller controls lifecycle. Poll may run on
 * another thread. Each poll result is owned UTF-8 JSON, release with
 * string_free. Destroy cancels, joins workers and drains queues: no callbacks
 * after release. All status codes: 0 success, -1 invalid/busy/unavailable. No
 * fake inference. */
int fs_abi_version(void);
/* Before worker startup only; 0 success, -1 unsupported key/invalid value. */
int fs_set_runtime_environment(const char *key, const char *value);
/* 1 verified helper identity; 0 mismatch or confirmed absent; -1 inspection
 * unavailable (never evidence that shutdown succeeded). */
int fs_process_matches(int64_t pid, const char *socket, const char *storage, const char *instance_id);
void fs_string_free(char *string);
char *fs_event_poll(void *handle, int timeout_ms);
void *fs_engine_create(const char *runtime_executable, const char *model_path);
/* Additive ABI v1: 0 llama.cpp CLI, 1 packaged LiteRT-LM CPU runner. */
void *fs_engine_create_backend(const char *runtime_executable, const char *model_path, int backend);
char *fs_engine_state(void *engine);
int fs_engine_probe(
    void *engine); /* synchronous actual model load; no retained KV/model */
int fs_engine_destroy(
    void *engine); /* reject while conversations reference it */
void *fs_conversation_create(void *engine);
int fs_generate(void *conversation, const char *request_id, const char *prompt);
/* Additive ABI v1 extension: constrained JSON, same stream/lifetime rules. */
int fs_generate_json(void *conversation, const char *request_id,
                     const char *prompt, const char *json_schema);
int fs_generate_options(void *conversation, const char *request_id,
                        const char *prompt, const char *json_schema, int max_output_tokens);
int fs_generation_cancel(void *conversation);
int fs_conversation_destroy(void *conversation, int cancel_and_drain);
void *fs_speech_create(const char *runtime_executable, const char *model_path);
int fs_speech_push(void *speech, const int16_t *samples, size_t count,
                   int sample_rate);
int fs_speech_finish(void *speech, const char *request_id);
int fs_speech_cancel(void *speech);
void fs_speech_destroy(void *speech);
/* target "auto" uses default device; playback sets stream.capture.sink=true.
 * PipeWire converts to mono signed 16-bit LE at sample_rate. Playback frames
 * contain rate*2*40/1000 bytes (3840 at 48kHz). Mic frames retain read buffer
 * sizes/even samples. Legacy channel map fields stay distinct; state/error
 * events use linux channel. */
void *fs_capture_start(const char *target, int playback, int sample_rate);
void *fs_capture_start_with_options(const char *target, int playback, int sample_rate, int echo_cancellation);
// Returns 1 if the native microphone route can accept the setting. Enabling on
// an existing standard engine takes effect on its next start; a processed engine
// changes bypass in place. Unsupported routes return 0 without changing capture.
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
 * Waits for startup up to timeout_ms (clamped 0..30000). No PCM is inspected or retained.
 * Completion does not prove permission: inspect permission_verified/code. */
char *fs_audio_request_system(int32_t timeout_ms);
/* Stateless utilities used by contract tests and import conversion. */
double fs_pcm_rms(const int16_t *samples, size_t count);
size_t fs_resample_pcm(const int16_t *input, size_t count, int input_rate,
                       int16_t *output, size_t capacity, int output_rate);
#ifdef __cplusplus
}
#endif
