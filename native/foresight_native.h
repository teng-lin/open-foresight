#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1. Handles are owned, single caller controls lifecycle. Poll may run on
 * another thread. Each poll result is owned UTF-8 JSON, release with
 * string_free. Destroy cancels, joins workers and drains queues: no callbacks
 * after release, except pending Mac startup as documented below. Poll may
 * overlap destroy: destroy wakes and joins existing polls, and a poll of a
 * retired handle returns null. The lifecycle owner must prevent new calls once
 * destroy starts and finish every non-poll call before destruction. Only
 * polling may overlap destruction; cancellation can overlap worker execution,
 * and must return before destroy starts. Other API calls on one handle are
 * serialized by the caller. Handle addresses must not be reused by a stale
 * caller after release. All status codes: 0 success, -1
 * invalid/busy/unavailable. No fake inference. */
int fs_abi_version(void);
/* Optional lifetime v2. Published base ABI v1 above is unchanged. New owned
 * handles are positive, monotonic 63-bit IDs, never resource addresses. Only
 * this native mapping resolves an ID. A retired ID cannot alias a new owner.
 * All owned creation is refused before physical work at 32 live execution
 * groups or 4096 retained operation records. Idle groups retain no resource.
 * Callers must serialize ordinary calls on one owner; retire may overlap them
 * and atomically revokes admission. It never waits for physical cleanup inline.
 * Legacy pointer entrypoints cannot operate on these owners or acknowledge
 * their tokens. Legacy creation/cleanup consumes no owned-API capacity.
 * Pending Mac legacy capture uses a separate bounded quarantine (see below).
 * Engine retire also revokes and joins all owned children. Successful retire
 * means actual callback/poll/worker/child reap and resource destruction. */
int fs_lifetime_version(void); /* currently 2 */
/* Mapping-wide admission is shared across Dart isolates. Status3 latches
 * refusal before publication; uncertain Dart acknowledgements explicitly
 * quarantine. There is no reset. Poll/state/cancel/cleanup and legacy retry
 * remain available. Admission returns1 while healthy,0 when process restart is
 * required. Its first successful call pins this exact loaded image and can
 * perform loader work. Quarantine and status3 publication only set the atomic
 * latch; neither performs that loader work or allocates. */
int fs_lifetime_admission(void);
void fs_lifetime_quarantine(void);
uint64_t fs_owned_engine_create(const char *runtime, const char *model,
                                int backend, int model_type);
uint64_t fs_owned_conversation_create(uint64_t engine);
uint64_t fs_owned_speech_create(const char *runtime, const char *model);
uint64_t fs_owned_capture_start(const char *target, int playback, int rate,
                                int echo);
char *fs_owned_engine_state(uint64_t owner);
char *fs_owned_event_poll(uint64_t owner, int timeout_ms);
int fs_owned_generate_options(uint64_t owner, const char *id,
                              const char *prompt, const char *schema,
                              int max_output_tokens);
int fs_owned_generate_tools(uint64_t owner, const char *id, const char *prompt,
                            const char *tools, int max_output_tokens);
int fs_owned_generation_tool_reply(uint64_t owner, const char *id,
                                   const char *message);
int fs_owned_generation_cancel(uint64_t owner);
int fs_owned_speech_push(uint64_t owner, const int16_t *samples, size_t count,
                         int rate);
int fs_owned_speech_finish(uint64_t owner, const char *id);
int fs_owned_speech_cancel(uint64_t owner);
int fs_owned_capture_set_echo_cancellation(uint64_t owner, int enabled);
/* Requests return a monotonic completion token, or0 on refusal. Repeated retire
 * by owner ID recovers the same token even after actual destruction. A probe
 * after completion starts fresh work. Speech reuse is refused natively until
 * the exact accepted request has actually joined. Capture finish retains final
 * queued PCM; separate retire destroys it. */
uint64_t fs_engine_probe_async(uint64_t owner);
uint64_t fs_engine_retire(uint64_t owner);
uint64_t fs_conversation_retire(uint64_t owner);
uint64_t fs_speech_retire(uint64_t owner);
uint64_t fs_speech_join_async(uint64_t owner);
uint64_t fs_capture_finish_async(uint64_t owner);
uint64_t fs_capture_retire(uint64_t owner);
/* 0 pending,1 success,2 known failure,3 cleanup unconfirmed/ownership retained,
 * -1 unknown/released. Unexpected cleanup failure publishes3 without releasing
 * resource authority. Retire may be explicitly retried by the same owner ID;
 * it reuses its idempotent cleanup state/token. Never hot-loop retries.
 * Probe/join/finish release is independent from owner retirement. */
int fs_operation_status(uint64_t token);
int fs_operation_release(uint64_t token);
/* Only confirmed successful retirement permits owner release. This acknowledges
 * its retirement metadata; other issued results keep independent
 * acknowledgements. Generic token release cannot consume retirement. Lost
 * release acknowledgement never authorizes pointer retry or false success.
 */
int fs_owner_release(uint64_t owner);
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
// State events announce phase=speech_queued before admission and
// phase=speech_running once this request owns its speech worker. A queued
// cancellation never stops a sibling's active request. Existing event consumers
// can ignore these metadata-only state events; no ABI signature changes.
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
 * Call fs_capture_stop after draining to release the handle. If Mac startup is
 * still pending, finish/stop revoke admission and retain cleanup asynchronously
 * in a separate 32-owner/64-record quarantine; they cannot confirm physical
 * completion to legacy callers. Use lifetime v2 for observable completion.
 * Ready captures retain synchronous final-PCM/drain and release behavior. */
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
