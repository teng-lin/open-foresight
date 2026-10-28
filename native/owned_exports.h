#pragma once
// Included inside the original mapping's extern "C" export block.
uint64_t fs_owned_engine_create(const char *runtime, const char *model,
                                int backend, int model_type) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        if (model_type < 0 || model_type > 17)
          return 0;
        NativeCreation creation;
        auto *handle = fs_engine_create_backend(runtime, model, backend);
        if (handle)
          static_cast<Engine *>(handle)->model_type = model_type;
        return native_identity(handle);
      },
      uint64_t{0});
}
uint64_t fs_owned_conversation_create(uint64_t engine) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeOwnerUse use(engine, NativeKind::engine, false, true);
        if (!use)
          return 0;
        NativeCreation creation;
        return native_identity(fs_conversation_create(use.get()));
      },
      uint64_t{0});
}
uint64_t fs_owned_speech_create(const char *runtime, const char *model) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeCreation creation;
        return native_identity(fs_speech_create(runtime, model));
      },
      uint64_t{0});
}
uint64_t fs_owned_capture_start(const char *target, int playback, int rate,
                                int echo) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeCreation creation;
        return native_identity(
            fs_capture_start_with_options(target, playback, rate, echo));
      },
      uint64_t{0});
}
int64_t fs_recording_monotonic_us() {
  return foresight::ffi_barrier(
      [] { return foresight::recording_monotonic_us(); }, int64_t{-1});
}
uint64_t fs_owned_recording_capture_start(const char *target, int playback,
                                          int echo, const char *options_json) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        auto options =
            foresight::recording_options(options_json, playback != 0);
        NativeCreation creation;
        return native_identity(start_capture_with_recording(
            target, playback, 48000, echo, std::move(options)));
      },
      uint64_t{0});
}
uint64_t fs_owned_recording_recover_start(int source,
                                          const char *options_json) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        auto options =
            foresight::recording_recovery_options(options_json, source);
        NativeCreation creation;
        return native_identity(start_capture_with_recording(
            "auto", source, 48000, 0, std::move(options), true));
      },
      uint64_t{0});
}
uint64_t fs_owned_recording_recover_join_async(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeOwnerUse use(owner, NativeKind::capture);
        if (!use || !static_cast<Capture *>(use.get())->recording_recovery)
          return 0;
        return request_native_work(owner, NativeKind::capture, false, false);
      },
      uint64_t{0});
}
uint64_t fs_owned_capture_reserve_async(uint64_t owner, const char *ids_json) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeOwnerUse use(owner, NativeKind::capture, false, true);
        if (!use)
          return 0;
        auto &capture = *static_cast<Capture *>(use.get());
        if (!capture.recording)
          return 0;
        auto value = foresight::recording_json(ids_json);
        foresight::recording_keys(value, {"chunk_ids"});
        auto request = std::make_shared<CaptureReservationRequest>();
        request->control = use.control;
        request->identities = foresight::recording_identities(
            value.at("chunk_ids"), capture.recording->identity);
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        if (use.control->closing)
          return 0;
        auto operation = registry.operations.create(
            native_capture_reserve, request.get(), use.control->group, owner);
        if (!registry.operations.submit(operation, request)) {
          registry.operations.discard(operation);
          return 0;
        }
        return operation->token;
      },
      uint64_t{0});
}
char *fs_owned_capture_recording_poll(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::capture);
        if (!use)
          return nullptr;
        auto &capture = *static_cast<Capture *>(use.get());
        if (!capture.recording)
          return nullptr;
        std::shared_ptr<foresight::RecordingWriter> writer;
        nlohmann::json value;
        std::vector<foresight::RecordingWriter::Chunk> recovered;
        {
          std::lock_guard lock(capture.recording_mutex);
          writer = capture.recording_writer;
          recovered.swap(capture.recording_recovered_chunks);
          value = {
              {"version", 1},
              {"ready", capture.recording_prepared},
              {"session_id", capture.recording->identity.session.data()},
              {"generation", capture.recording->identity.generation.data()},
              {"source", capture.recording->identity.source},
              {"span", capture.recording->span},
              {"state",
               !capture.recording_error.empty() ? "failed"
               : capture.recording_sealed       ? "sealed"
               : capture.recording_prepared
                   ? (capture.recording_acquired.load()
                          ? (capture.active.load() ? "capturing" : "sealing")
                          : "starting")
                   : "preparing"},
              {"capture_active", capture.active.load() &&
                                     capture.recording_prepared &&
                                     capture.recording_acquired.load() &&
                                     capture.recording_error.empty() &&
                                     !capture.recording_sealed},
              {"error", capture.recording_error.empty()
                            ? nlohmann::json(nullptr)
                            : nlohmann::json(capture.recording_error)},
              {"clock_quality", capture.recording_clock_quality},
              {"uncertainty_us", nullptr},
              {"source_sample", capture.recording_source_sample.load()},
              {"acquired_through_us",
               capture.recording_acquired_through_us.load() < 0
                   ? nlohmann::json(nullptr)
                   : nlohmann::json(
                         capture.recording_acquired_through_us.load())},
              {"current_volume", capture.recording_volume.load()},
              {"peak_volume", capture.recording_peak.load()},
              {"last_voice_capture_us",
               capture.recording_last_voice_us.load() < 0
                   ? nlohmann::json(nullptr)
                   : nlohmann::json(capture.recording_last_voice_us.load())}};
        }
        value["chunks"] = nlohmann::json::array();
        if (writer) {
          auto pressure = writer->pressure();
          value["queued_frames"] = pressure.queued_frames;
          value["reserved_chunks"] = pressure.ready_chunks;
          value["ready_chunks"] = pressure.published_chunks;
          value["outstanding_chunks"] = pressure.outstanding_chunks;
          for (auto &chunk : writer->drainPublished())
            value["chunks"].push_back(foresight::recording_chunk_json(chunk));
        } else {
          value["queued_frames"] = 0;
          value["ready_chunks"] = recovered.size();
          value["reserved_chunks"] = 0;
          value["outstanding_chunks"] = 0;
        }
        for (auto &chunk : recovered)
          value["chunks"].push_back(foresight::recording_chunk_json(chunk));
        return owned(value.dump());
      },
      static_cast<char *>(nullptr));
}
char *fs_owned_engine_state(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::engine);
        return use ? fs_engine_state(use.get()) : static_cast<char *>(nullptr);
      },
      static_cast<char *>(nullptr));
}
char *fs_owned_event_poll(uint64_t owner, int timeout) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::conversation, true);
        return use ? fs_event_poll(use.get(), timeout)
                   : static_cast<char *>(nullptr);
      },
      static_cast<char *>(nullptr));
}
int fs_owned_generate_options(uint64_t owner, const char *id,
                              const char *prompt, const char *schema,
                              int max_output_tokens) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::conversation, false, true);
        return use ? fs_generate_options(use.get(), id, prompt, schema,
                                         max_output_tokens)
                   : -1;
      },
      -1);
}
int fs_owned_generate_tools(uint64_t owner, const char *id, const char *prompt,
                            const char *tools, int max_output_tokens) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::conversation, false, true);
        return use ? fs_generate_tools(use.get(), id, prompt, tools,
                                       max_output_tokens)
                   : -1;
      },
      -1);
}
int fs_owned_generation_tool_reply(uint64_t owner, const char *id,
                                   const char *message) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::conversation, false, true);
        return use ? fs_generation_tool_reply(use.get(), id, message) : -1;
      },
      -1);
}
int fs_owned_generation_cancel(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::conversation);
        return use ? fs_generation_cancel(use.get()) : -1;
      },
      -1);
}
int fs_owned_speech_push(uint64_t owner, const int16_t *samples, size_t count,
                         int rate) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::speech, false, true);
        return use ? fs_speech_push(use.get(), samples, count, rate) : -1;
      },
      -1);
}
int fs_owned_speech_finish(uint64_t owner, const char *id) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::speech, false, true);
        return use ? fs_speech_finish(use.get(), id) : -1;
      },
      -1);
}
int fs_owned_speech_cancel(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::speech);
        return use ? fs_speech_cancel(use.get()) : -1;
      },
      -1);
}
int fs_owned_capture_set_echo_cancellation(uint64_t owner, int enabled) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::capture, false, true);
        return use ? fs_capture_set_echo_cancellation(use.get(), enabled) : -1;
      },
      -1);
}
int fs_owner_release(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> int {
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        const auto found = registry.owners.find(owner);
        if (found == registry.owners.end() ||
            registry.operations.status(found->second->retire) != 1 ||
            found->second->object ||
            !registry.operations.release_owner(owner, found->second->retire))
          return -1;
        registry.owners.erase(found);
        return 0;
      },
      -1);
}

#include "media_owned_exports.h"

#include "pcm_output_owned_exports.h"
