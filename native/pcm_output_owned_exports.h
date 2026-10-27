#pragma once
// Service-only PCM capability; no file/model/worker identity enters this ABI.
int fs_pcm_output_version() {
  return 1;
}
uint64_t fs_owned_pcm_output_create_async(const char *options_json) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        if (!options_json || strnlen(options_json, 2049) > 2048)
          return 0;
        auto options = nlohmann::json::parse(options_json);
        if (!options.is_object() || options.size() < 2 || options.size() > 3 ||
            !options.contains("version") || !options.contains("generation") ||
            options.at("version") != 1 ||
            !options.at("generation").is_number_integer())
          return 0;
        for (auto it = options.begin(); it != options.end(); ++it)
          if (it.key() != "version" && it.key() != "generation" &&
              it.key() != "target")
            return 0;
        const auto generation = options.at("generation").get<int64_t>();
        if (generation <= 0)
          return 0;
        std::string target;
        if (options.contains("target")) {
          if (!options.at("target").is_string())
            return 0;
          target = options.at("target").get<std::string>();
          if (target.size() > 1024)
            return 0;
          for (unsigned char character : target)
            if (character < 32 || character == 127)
              return 0;
        }
        NativeCreation creation;
        auto factory = foresight::make_pcm_output_backend;
#if FORESIGHT_ENABLE_TEST_HOOKS
        if (pcm_output_factory_for_testing)
          factory = pcm_output_factory_for_testing;
#endif
        auto *output = publish_native(
            std::make_unique<foresight::PcmOutput>(uint64_t(generation),
                                                   std::move(target), factory),
            NativeKind::output);
        auto rollback =
            foresight::ScopeExit([&] { rollback_unpublished_native(output); });
        const auto identity = native_identity(output);
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        const auto control = registry.owners.at(identity);
        if (!registry.operations.submit(
                registry.operations.find(control->probe), control))
          return 0;
        rollback.release();
        return identity;
      },
      uint64_t{0});
}
int fs_owned_pcm_output_push(uint64_t owner, uint64_t generation,
                             const int16_t *pcm, size_t frames) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::output, false, true);
        if (!use)
          return -1;
        return static_cast<foresight::PcmOutput *>(use.get())->push(
            generation, pcm, frames);
      },
      -1);
}
char *fs_owned_pcm_output_poll(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::output);
        if (!use)
          return nullptr;
        const auto value =
            static_cast<foresight::PcmOutput *>(use.get())->snapshot();
        const auto *error = foresight::PcmOutput::error_name(value.error);
        auto result =
            nlohmann::json{{"version", 1},
                           {"generation", value.generation},
                           {"ready", value.ready},
                           {"paused", value.paused},
                           {"stopped", value.stopped},
                           {"queued_frames", value.queued_frames},
                           {"rendered_frames", value.rendered_frames},
                           {"underruns", value.underruns},
                           {"buffering", value.buffering},
                           {"start_token", use.control->probe},
                           {"error", *error ? nlohmann::json(error)
                                            : nlohmann::json(nullptr)}}
                .dump();
        return strdup(result.c_str());
      },
      static_cast<char *>(nullptr));
}
uint64_t fs_owned_pcm_output_pause_flush_async(uint64_t owner,
                                               uint64_t generation) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeOwnerUse use(owner, NativeKind::output, false, true);
        if (!use)
          return 0;
        auto request = std::make_shared<PcmOutputRequest>();
        request->control = use.control;
        request->generation = generation;
        request->flush = true;
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        if (use.control->closing)
          return 0;
        auto operation = registry.operations.create(
            native_output_control, request.get(), use.control->group, owner);
        if (!static_cast<foresight::PcmOutput *>(use.get())->request_flush(
                generation)) {
          registry.operations.discard(operation);
          return 0;
        }
        if (!registry.operations.submit(operation, request)) {
          static_cast<foresight::PcmOutput *>(use.get())->revoke();
          registry.operations.discard(operation);
          return 0;
        }
        return operation->token;
      },
      uint64_t{0});
}
uint64_t fs_owned_pcm_output_resume_async(uint64_t owner, uint64_t generation) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeOwnerUse use(owner, NativeKind::output, false, true);
        if (!use || !generation || generation > uint64_t(INT64_MAX))
          return 0;
        auto request = std::make_shared<PcmOutputRequest>();
        request->control = use.control;
        request->generation = generation;
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        if (use.control->closing)
          return 0;
        auto operation = registry.operations.create(
            native_output_control, request.get(), use.control->group, owner);
        if (!registry.operations.submit(operation, request)) {
          registry.operations.discard(operation);
          return 0;
        }
        return operation->token;
      },
      uint64_t{0});
}
uint64_t fs_pcm_output_finish_async(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        const auto found = registry.owners.find(owner);
        if (found == registry.owners.end() ||
            found->second->kind != NativeKind::output ||
            found->second->closing || !found->second->object)
          return 0;
        const auto control = found->second;
        static_cast<foresight::PcmOutput *>(control->object.get())->revoke();
        auto operation = registry.operations.find(control->finish);
        if (!operation)
          return 0;
        if (operation->state == NativeOperation::State::idle ||
            operation->state == NativeOperation::State::unconfirmed)
          if (!registry.operations.submit(operation, control))
            return 0;
        return control->finish;
      },
      uint64_t{0});
}
uint64_t fs_pcm_output_retire(uint64_t owner) {
  return foresight::ffi_barrier(
      [&] { return retire_native(owner, NativeKind::output); }, uint64_t{0});
}
