#pragma once
// Included inside the mapping's extern "C" export block. No media path or
// executable identity is accepted from RPC: this is a service-only FD ABI.
uint64_t fs_owned_media_start(int operation, int input_fd, int second_input_fd,
                              int output_fd, int owner_lock_fd,
                              const char *options_json) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        NativeCreation creation;
        auto resource = std::make_unique<foresight::MediaOwner>(
            operation, input_fd, second_input_fd, output_fd, owner_lock_fd,
            options_json);
        auto *media = publish_native(std::move(resource), NativeKind::media);
        auto rollback =
            foresight::ScopeExit([&] { rollback_unpublished_native(media); });
        uint64_t identity = native_identity(media);
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        auto control = registry.owners.at(identity);
        auto action = registry.operations.find(control->finish);
        if (!registry.operations.submit(action, control))
          return 0;
        rollback.release();
        return identity;
      },
      uint64_t{0});
}
char *fs_owned_media_poll(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::media);
        if (!use)
          return nullptr;
        auto result =
            static_cast<foresight::MediaOwner *>(use.get())->poll().dump();
        return strdup(result.c_str());
      },
      static_cast<char *>(nullptr));
}
int fs_owned_media_cancel(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::media);
        if (!use)
          return -1;
        static_cast<foresight::MediaOwner *>(use.get())->request_cancel();
        return 0;
      },
      -1);
}
int fs_owned_media_progress(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::media);
        if (!use)
          return -1;
        static_cast<foresight::MediaOwner *>(use.get())->progress.fetch_add(1);
        return 0;
      },
      -1);
}
char *fs_owned_media_input_poll(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> char * {
        NativeOwnerUse use(owner, NativeKind::media);
        if (!use)
          return nullptr;
        auto request =
            static_cast<foresight::MediaOwner *>(use.get())->input_poll();
        if (request.is_null())
          return nullptr;
        return strdup(request.dump().c_str());
      },
      static_cast<char *>(nullptr));
}
int fs_owned_media_input_reply(uint64_t owner, uint64_t sequence, int status,
                               int first_fd, int second_fd) {
  return foresight::ffi_barrier(
      [&]() -> int {
        NativeOwnerUse use(owner, NativeKind::media);
        if (!use)
          return -1;
        return static_cast<foresight::MediaOwner *>(use.get())->input_reply(
            sequence, status, first_fd, second_fd);
      },
      -1);
}
uint64_t fs_media_join_async(uint64_t owner) {
  return foresight::ffi_barrier(
      [&]() -> uint64_t {
        auto &registry = native_handles();
        std::lock_guard lock(registry.mutex);
        auto found = registry.owners.find(owner);
        if (found == registry.owners.end() ||
            found->second->kind != NativeKind::media ||
            found->second->closing || !found->second->object)
          return 0;
        auto &control = found->second;
        auto operation = registry.operations.find(control->finish);
        if (!operation)
          return 0;
        if (operation->state == NativeOperation::State::unconfirmed)
          registry.operations.submit(operation, control);
        return control->finish;
      },
      uint64_t{0});
}
uint64_t fs_media_retire(uint64_t owner) {
  return foresight::ffi_barrier(
      [&] { return retire_native(owner, NativeKind::media); }, uint64_t{0});
}
