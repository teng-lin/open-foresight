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
        NativeOwnerUse use(engine, NativeKind::engine);
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
        NativeOwnerUse use(owner, NativeKind::conversation);
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
        NativeOwnerUse use(owner, NativeKind::conversation);
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
        NativeOwnerUse use(owner, NativeKind::conversation);
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
        NativeOwnerUse use(owner, NativeKind::speech);
        return use ? fs_speech_push(use.get(), samples, count, rate) : -1;
      },
      -1);
}
int fs_owned_speech_finish(uint64_t owner, const char *id) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::speech);
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
        NativeOwnerUse use(owner, NativeKind::capture);
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
