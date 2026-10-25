#define _GNU_SOURCE
#include "diagnostic_support.h"

#include "diagnostic_endpoint.h"
#include "diagnostic_inherited.h"
#include "diagnostic_kernel.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/pidfd.h>
#include <sys/wait.h>
#else
#include <sys/event.h>
#include <sys/random.h>
#endif

#ifndef FORESIGHT_DIAGNOSTIC_NATIVE_ID
#error Build tooling must supply the diagnostic native input identity
#endif
static const char native_identity[] = FORESIGHT_DIAGNOSTIC_NATIVE_ID;
_Static_assert(sizeof(native_identity) == 65, "native identity length");

// Fixed process-local storage. No native allocation/finalizer can reclaim or
// reuse it while a late FFI call or a peer still owns the mapping.
typedef struct support_context {
  atomic_int claimed;
  atomic_int status;
  atomic_int cancel;
  atomic_int prepared_once;
  atomic_int spawned_once;
  atomic_int mapped_once;
  atomic_int watcher_seen;
  atomic_int control_ready;
  atomic_int init_received;
  atomic_int exit_class;
  atomic_flag poll_busy;
  atomic_flag watch_busy;
  atomic_uint_fast64_t operation_deadline;
  _Atomic(fs_diag_page *) page;
  int role;
  pid_t parent;
  int page_fd;
  atomic_int process_fd;
#ifdef __APPLE__
  pid_t birth_pid;
  int exit_event;
#endif
  uint8_t native_id[32];
  uint8_t dart_id[32];
  uint8_t catalog_id[32];
  uint8_t nonce[32];
  uint64_t probe;
  uint64_t force;
  uint64_t bootstrap_deadline;
  uint64_t last_parent_beat;
  uint64_t parent_beat_deadline;
  fs_diag_endpoint endpoint;
  char arguments[2048];
  char *argv[17];
} support_context;

static support_context context = {.poll_busy = ATOMIC_FLAG_INIT,
                                  .watch_busy = ATOMIC_FLAG_INIT};
_Static_assert(sizeof(support_context) < 4096, "bounded native context");

static uint64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static int decode_identity(const char *text, uint8_t *output) {
  if (text == NULL || strnlen(text, 65) != 64)
    return 0;
  for (unsigned i = 0; i != 32; ++i) {
    unsigned value = 0;
    for (unsigned n = 0; n != 2; ++n) {
      unsigned char c = (unsigned char)text[2 * i + n];
      if (c >= '0' && c <= '9')
        value = value * 16 + c - '0';
      else if (c >= 'a' && c <= 'f')
        value = value * 16 + c - 'a' + 10;
      else
        return 0;
    }
    output[i] = (uint8_t)value;
  }
  return 1;
}

static int reserve(int role, const char *native_id, const char *dart_id,
                   const char *catalog_id) {
  // A rejected call consumes this one attempt too. No repeated namespace,
  // mapping or native context allocation is possible after any failure.
  int empty = 0;
  if (!atomic_compare_exchange_strong(&context.claimed, &empty, 1))
    return 0;
  context.role = role;
  context.page_fd = -1;
  context.process_fd = -1;
  if (native_id == NULL || strnlen(native_id, 65) != 64 ||
      strcmp(native_id, native_identity) != 0 ||
      !decode_identity(native_id, context.native_id) ||
      !decode_identity(dart_id, context.dart_id) ||
      !decode_identity(catalog_id, context.catalog_id)) {
    atomic_store(&context.status, FS_DIAG_SUPPORT_FAILED);
    return 0;
  }
  return 1;
}

static int valid(uint64_t id, int role) {
  return id == 1 && (atomic_load(&context.status) & FS_DIAG_SUPPORT_RESERVED) &&
         context.role == role;
}

static int fail(void) {
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_FAILED);
  return FS_DIAG_SUPPORT_ERROR;
}

uint64_t fs_diag_parent_reserve(const char *native_id, const char *dart_id,
                                const char *catalog_id,
                                const uint8_t *argv_bytes, uint32_t length,
                                uint32_t argc) {
  if (!reserve(FS_DIAG_ENDPOINT_PARENT, native_id, dart_id, catalog_id))
    return 0;
  if (argv_bytes == NULL || length == 0 || length > sizeof(context.arguments) ||
      argc < 4 || argc > 16)
    goto bad;
  memcpy(context.arguments, argv_bytes, length);
  uint32_t offset = 0;
  for (uint32_t i = 0; i != argc; ++i) {
    if (offset >= length)
      goto bad;
    size_t size = strnlen(context.arguments + offset, length - offset);
    if (size == 0 || size > 1024 || size >= length - offset)
      goto bad;
    context.argv[i] = context.arguments + offset;
    offset += (uint32_t)size + 1;
  }
  char parent[24];
  context.parent = getpid();
  int count = snprintf(parent, sizeof(parent), "%ld", (long)context.parent);
  if (offset != length || count < 1 || (size_t)count >= sizeof(parent) ||
      context.argv[0][0] != '/' || context.argv[3][0] != '/' ||
      strcmp(context.argv[1], native_identity) != 0 ||
      strcmp(context.argv[2], parent) != 0)
    goto bad;
  context.argv[argc] = NULL;
  atomic_store(&context.status, FS_DIAG_SUPPORT_RESERVED);
  return 1;
bad:
  fail();
  return 0;
}

int fs_diag_parent_prepare(uint64_t id) {
  int unused = 0;
  if (!valid(id, FS_DIAG_ENDPOINT_PARENT) ||
      (atomic_load(&context.status) & FS_DIAG_SUPPORT_FAILED) ||
      !atomic_compare_exchange_strong(&context.prepared_once, &unused, 1))
    return FS_DIAG_SUPPORT_ERROR;
  if (atomic_load(&context.cancel))
    return FS_DIAG_SUPPORT_CANCELLED;
  fs_diag_kernel_page kernel;
  if (fs_diag_kernel_page_create(&kernel) != FS_DIAG_KERNEL_OK)
    return fail();
  // Only this prepare call owns the fresh FD until it publishes PREPARED.
  // A failure retains the bounded mapping but closes its known kernel FD.
  uint64_t random;
  if (getentropy(context.nonce, sizeof(context.nonce)) != 0 ||
      getentropy(&random, sizeof(random)) != 0) {
    close(kernel.descriptor);
    return fail();
  }
  context.probe = FS_DIAG_PROBE | (random % (FS_DIAG_CHALLENGE_MASK - 1) + 1);
  context.force =
      FS_DIAG_FORCE_RETIRE | ((context.probe & FS_DIAG_CHALLENGE_MASK) + 1);
  fs_diag_page *page = kernel.mapping;
  memset(page, 0, sizeof(*page));
  page->header.magic = FS_DIAG_PAGE_MAGIC;
  page->header.version = FS_DIAG_PROTOCOL_VERSION;
  page->header.header_bytes = FS_DIAG_HEADER_BYTES;
  page->header.generation = 1;
  page->header.application_pid = (uint64_t)context.parent;
  memcpy(page->header.nonce, context.nonce, 32);
  memcpy(page->header.native_id, context.native_id, 32);
  memcpy(page->header.dart_id, context.dart_id, 32);
  memcpy(page->header.catalog_id, context.catalog_id, 32);
#define INIT_WORD(name) atomic_init(&page->header.name, 0)
  INIT_WORD(child_pid);
  INIT_WORD(parent_heartbeat);
  INIT_WORD(control_command);
  INIT_WORD(control_ack);
  INIT_WORD(request_published);
  INIT_WORD(request_consumed);
  INIT_WORD(reply_published);
  INIT_WORD(reply_consumed);
  INIT_WORD(state);
  INIT_WORD(child_heartbeat);
#undef INIT_WORD
  if (fs_diag_endpoint_init(&context.endpoint, page, FS_DIAG_ENDPOINT_PARENT) !=
      FS_DIAG_CHANNEL_COMPLETE) {
    close(kernel.descriptor);
    return fail();
  }
  atomic_store(&context.page, page);
  if (atomic_load(&context.cancel)) {
    close(kernel.descriptor);
    atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_CANCELLED);
    return FS_DIAG_SUPPORT_CANCELLED;
  }
  context.page_fd = kernel.descriptor;
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_PREPARED);
  return FS_DIAG_SUPPORT_PREPARED;
}

#ifdef __APPLE__
static int watch_process(pid_t pid) {
  int queue = kqueue();
  if (queue < 0)
    return -1;
  // Darwin kqueue descriptors are created close-on-exec by the kernel. Verify
  // that guarantee; never repair a non-atomic descriptor after publication.
  if (fcntl(queue, F_GETFD) != FD_CLOEXEC) {
    int saved = errno;
    close(queue);
    errno = saved;
    return -1;
  }
  struct kevent event;
  EV_SET(&event, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT,
         NOTE_EXIT, 0, NULL);
  if (kevent(queue, &event, 1, NULL, 0, NULL) != 0) {
    int saved = errno;
    close(queue);
    errno = saved;
    return -1;
  }
  return queue;
}

static int process_exited(int descriptor, pid_t pid) {
  struct kevent event;
  const struct timespec immediate = {0, 0};
  int count = kevent(descriptor, NULL, 0, &event, 1, &immediate);
  if (count <= 0)
    return count;
  if (event.filter != EVFILT_PROC || event.ident != (uintptr_t)pid ||
      (event.flags & EV_ERROR) || !(event.fflags & NOTE_EXIT))
    return -1;
  return 1;
}
#else
static int process_exited(int descriptor) {
  struct pollfd observed = {.fd = descriptor, .events = POLLIN};
  int count = poll(&observed, 1, 0);
  if (count <= 0)
    return count;
  if (observed.revents & (POLLERR | POLLNVAL))
    return -1;
  return (observed.revents & (POLLIN | POLLHUP)) ? 1 : 0;
}
#endif

int fs_diag_parent_spawn(uint64_t id) {
  int unused = 0;
  if (!valid(id, FS_DIAG_ENDPOINT_PARENT) ||
      (atomic_load(&context.status) & FS_DIAG_SUPPORT_FAILED) ||
      !(atomic_load(&context.status) & FS_DIAG_SUPPORT_PREPARED) ||
      !atomic_compare_exchange_strong(&context.spawned_once, &unused, 1))
    return FS_DIAG_SUPPORT_ERROR;
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_SPAWNING);
  if (atomic_load(&context.cancel)) {
    close(context.page_fd);
    context.page_fd = -1;
    atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_CANCELLED);
    return FS_DIAG_SUPPORT_CANCELLED;
  }
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int error = posix_spawn_file_actions_init(&actions);
  if (error)
    goto finish;
  error = posix_spawnattr_init(&attributes);
  if (error) {
    posix_spawn_file_actions_destroy(&actions);
    goto finish;
  }
  sigset_t empty, defaults;
  sigemptyset(&empty);
  sigemptyset(&defaults);
  const int signals[] = {SIGINT, SIGHUP, SIGTERM, SIGQUIT, SIGPIPE};
  for (unsigned i = 0; i != sizeof(signals) / sizeof(signals[0]); ++i)
    sigaddset(&defaults, signals[i]);
  short flags =
      POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
#define ACTION(call)                                                           \
  do {                                                                         \
    if (!error)                                                                \
      error = (call);                                                          \
  } while (0)
  ACTION(posix_spawnattr_setflags(&attributes, flags));
  ACTION(posix_spawnattr_setsigmask(&attributes, &empty));
  ACTION(posix_spawnattr_setsigdefault(&attributes, &defaults));
  ACTION(posix_spawnattr_setpgroup(&attributes, 0));
  ACTION(posix_spawn_file_actions_addchdir_np(&actions, "/"));
  ACTION(posix_spawn_file_actions_adddup2(&actions, context.page_fd,
                                          FS_DIAG_CHILD_FD));
  for (int fd = 0; fd != 3; ++fd)
    ACTION(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                                            fd == 0 ? O_RDONLY : O_WRONLY, 0));
  char *const environment[] = {"LANG=C", "LC_ALL=C", NULL};
#ifdef __linux__
  int birth = -1;
  ACTION(pidfd_spawn(&birth, context.argv[0], &actions, &attributes,
                     context.argv, environment));
  if (!error)
    context.process_fd = birth;
#else
  pid_t birth = 0;
  ACTION(posix_spawn(&birth, context.argv[0], &actions, &attributes,
                     context.argv, environment));
  if (!error) {
    context.birth_pid = birth;
    context.process_fd = watch_process(birth);
    if (context.process_fd < 0) {
      if (errno == ESRCH)
        atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_NOT_LIVE);
      else
        error = errno ? errno : EIO;
    }
  }
#endif
#undef ACTION
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
finish:
  close(context.page_fd);
  context.page_fd = -1;
  if (error) {
    // Private FORCE can retire an unbound child after watch registration fails.
    // Without SPAWNED, that ACK never binds a failed watch or grants PID
    // rights.
    atomic_store(&atomic_load(&context.page)->header.control_command,
                 context.force);
    return fail();
  }
  // Publish a fresh challenge only AFTER the Darwin watch exists. A missing
  // watch/ACK never grants authority against a guessed or reused PID.
  atomic_store(&context.control_ready, 1);
  uint64_t empty_command = 0;
  atomic_compare_exchange_strong(
      &atomic_load(&context.page)->header.control_command, &empty_command,
      context.probe);
  // FORCE on either side of publication must be the final command. A request
  // before control_ready sets cancel only, preventing pre-registration ACKs.
  if (atomic_load(&context.cancel))
    atomic_store(&atomic_load(&context.page)->header.control_command,
                 context.force);
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_SPAWNED);
  return FS_DIAG_SUPPORT_SPAWNED;
}

int fs_diag_parent_force(uint64_t id) {
  if (!valid(id, FS_DIAG_ENDPOINT_PARENT))
    return FS_DIAG_SUPPORT_ERROR;
  atomic_store(&context.cancel, 1);
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_CANCELLED);
  fs_diag_page *page = atomic_load(&context.page);
  if (page != NULL && atomic_load(&context.control_ready))
    atomic_store(&page->header.control_command, context.force);
  return FS_DIAG_SUPPORT_CANCELLED;
}

int fs_diag_parent_heartbeat(uint64_t id) {
  if (!valid(id, FS_DIAG_ENDPOINT_PARENT))
    return FS_DIAG_SUPPORT_ERROR;
  fs_diag_page *page = atomic_load(&context.page);
  if (page == NULL)
    return FS_DIAG_SUPPORT_ERROR;
  // No sequence reuse, including after impractically long runtimes.
  uint64_t beat = atomic_load(&page->header.parent_heartbeat);
  if (beat >= FS_DIAG_MAX_SEQUENCE)
    return fail();
  atomic_store(&page->header.parent_heartbeat, beat + 1);
  return 0;
}

static int parent_poll(void) {
  int status = atomic_load(&context.status);
  if (!(status & FS_DIAG_SUPPORT_SPAWNED) ||
      (status & FS_DIAG_SUPPORT_NOT_LIVE))
    return status;
  fs_diag_page *page = atomic_load(&context.page);
  uint64_t ack = atomic_load(&page->header.control_ack);
  if (ack == context.probe || ack == context.force)
    atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_WATCH_BOUND);
  if (context.process_fd < 0)
    return atomic_load(&context.status);
#ifdef __linux__
  int exited = process_exited(context.process_fd);
  if (exited > 0) {
    atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_NOT_LIVE);
    siginfo_t information = {0};
    if (waitid(P_PIDFD, (id_t)context.process_fd, &information,
               WEXITED | WNOHANG) == 0 &&
        information.si_pid != 0) {
      int classification = FS_DIAG_EXIT_SIGNAL;
      if (information.si_code == CLD_EXITED) {
        classification =
            information.si_status == 0 ? FS_DIAG_EXIT_NORMAL
            : information.si_status >= 64 && information.si_status <= 67
                ? information.si_status
                : FS_DIAG_EXIT_OTHER;
      }
      atomic_store(&context.exit_class, classification);
      atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_REAPED);
    }
    // ECHILD may mean another actual VM reaper consumed it. NOT_LIVE comes
    // from the birth handle, never ECHILD or an inferred PID status.
    close(context.process_fd);
    context.process_fd = -1;
  }
#else
  int exited = context.exit_event
                   ? 1
                   : process_exited(context.process_fd, context.birth_pid);
  if (exited > 0) {
    context.exit_event = 1;
    if (atomic_load(&context.status) & FS_DIAG_SUPPORT_WATCH_BOUND) {
      atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_NOT_LIVE);
      close(context.process_fd);
      context.process_fd = -1;
    }
  }
#endif
  if (exited < 0)
    fail();
  return atomic_load(&context.status);
}

int fs_diag_parent_poll(uint64_t id) {
  if (!valid(id, FS_DIAG_ENDPOINT_PARENT))
    return FS_DIAG_SUPPORT_ERROR;
  if (atomic_flag_test_and_set(&context.poll_busy))
    return atomic_load(&context.status);
  int result = parent_poll();
  atomic_flag_clear(&context.poll_busy);
  return result;
}

int fs_diag_parent_exit_class(uint64_t id) {
  return valid(id, FS_DIAG_ENDPOINT_PARENT) ? atomic_load(&context.exit_class)
                                            : FS_DIAG_SUPPORT_ERROR;
}

uint64_t fs_diag_child_arm(int64_t expected_parent, const char *native_id,
                           const char *dart_id, const char *catalog_id) {
  if (!reserve(FS_DIAG_ENDPOINT_CHILD, native_id, dart_id, catalog_id))
    return 0;
  uint64_t now = monotonic_ms();
  if (expected_parent <= 1 || expected_parent > INT_MAX || now == 0 ||
      getppid() != (pid_t)expected_parent)
    goto bad;
  context.parent = (pid_t)expected_parent;
  context.bootstrap_deadline = now + 1000;
  context.parent_beat_deadline = now + 5000;
#ifdef __linux__
  context.process_fd = pidfd_open(context.parent, 0);
#else
  context.process_fd = watch_process(context.parent);
#endif
  if (context.process_fd < 0 || getppid() != context.parent)
    goto bad;
  atomic_store(&context.status, FS_DIAG_SUPPORT_RESERVED);
  return 1;
bad:
  if (context.process_fd >= 0) {
    close(context.process_fd);
    context.process_fd = -1;
  }
  fail();
  return 0;
}

static int header_valid(fs_diag_page *page) {
  return page != NULL && page->header.magic == FS_DIAG_PAGE_MAGIC &&
         page->header.version == FS_DIAG_PROTOCOL_VERSION &&
         page->header.header_bytes == FS_DIAG_HEADER_BYTES &&
         page->header.generation == 1 &&
         page->header.application_pid == (uint64_t)context.parent &&
         memcmp(page->header.native_id, context.native_id, 32) == 0 &&
         memcmp(page->header.dart_id, context.dart_id, 32) == 0 &&
         memcmp(page->header.catalog_id, context.catalog_id, 32) == 0;
}

int fs_diag_child_map(uint64_t id) {
  int unused = 0;
  if (!valid(id, FS_DIAG_ENDPOINT_CHILD) ||
      !atomic_load(&context.watcher_seen) ||
      (atomic_load(&context.status) & FS_DIAG_SUPPORT_FAILED) ||
      !atomic_compare_exchange_strong(&context.mapped_once, &unused, 1))
    return FS_DIAG_SUPPORT_ERROR;
  fs_diag_page *page;
  if (fs_diag_inherited_page_open(&page) != FS_DIAG_INHERITED_OK ||
      !header_valid(page))
    return fail();
  unsigned nonce_bits = 0;
  for (unsigned i = 0; i != 32; ++i)
    nonce_bits |= page->header.nonce[i];
  if (nonce_bits == 0 || atomic_load(&page->header.child_pid) != 0 ||
      atomic_load(&page->header.state) != 0 ||
      fs_diag_endpoint_init(&context.endpoint, page, FS_DIAG_ENDPOINT_CHILD) !=
          FS_DIAG_CHANNEL_COMPLETE)
    return fail();
  memcpy(context.nonce, page->header.nonce, 32);
  atomic_store(&page->header.child_pid, (uint64_t)getpid());
  atomic_store(&page->header.state, 1);
  atomic_store(&context.page, page);
  atomic_fetch_or(&context.status, FS_DIAG_SUPPORT_PREPARED);
  return FS_DIAG_SUPPORT_PREPARED;
}

int fs_diag_child_operation(uint64_t id, int active) {
  if (!valid(id, FS_DIAG_ENDPOINT_CHILD) || (active != 0 && active != 1))
    return FS_DIAG_SUPPORT_ERROR;
  uint64_t now = monotonic_ms();
  if (now == 0)
    return fail();
  atomic_store(&context.operation_deadline, active ? now + 5000 : 0);
  return 0;
}

int fs_diag_child_watch(uint64_t id) {
  if (!valid(id, FS_DIAG_ENDPOINT_CHILD))
    return FS_DIAG_SUPPORT_ERROR;
  if (atomic_load(&context.status) & FS_DIAG_SUPPORT_FAILED)
    _exit(67);
  if (atomic_flag_test_and_set(&context.watch_busy))
    return FS_DIAG_SUPPORT_ERROR;
  uint64_t now = monotonic_ms();
  if (now == 0 || getppid() != context.parent)
    _exit(66);
#ifdef __linux__
  int exited = process_exited(context.process_fd);
#else
  int exited = process_exited(context.process_fd, context.parent);
#endif
  if (exited != 0)
    _exit(66);
  atomic_store(&context.watcher_seen, 1);
  if (!atomic_load(&context.init_received) && now >= context.bootstrap_deadline)
    _exit(65);
  fs_diag_page *page = atomic_load(&context.page);
  if (page == NULL) {
    if (now >= context.bootstrap_deadline)
      _exit(65);
    atomic_flag_clear(&context.watch_busy);
    return 0;
  }
  if (!header_valid(page) || memcmp(page->header.nonce, context.nonce, 32) != 0)
    _exit(67);
  uint64_t control = atomic_load(&page->header.control_command);
  uint64_t kind = control & ~FS_DIAG_CHALLENGE_MASK;
  if ((control & FS_DIAG_CHALLENGE_MASK) != 0 &&
      (kind == FS_DIAG_PROBE || kind == FS_DIAG_FORCE_RETIRE)) {
    atomic_store(&page->header.control_ack, control);
    if (kind == FS_DIAG_FORCE_RETIRE)
      _exit(66);
  }
  uint64_t beat = atomic_load(&page->header.parent_heartbeat);
  if (beat != context.last_parent_beat) {
    context.last_parent_beat = beat;
    context.parent_beat_deadline = now + 5000;
  }
  uint64_t operation = atomic_load(&context.operation_deadline);
  if (now >= context.parent_beat_deadline ||
      (operation != 0 && now >= operation))
    _exit(66);
  uint64_t child_beat = atomic_load(&page->header.child_heartbeat);
  if (child_beat >= FS_DIAG_MAX_SEQUENCE)
    _exit(67);
  atomic_store(&page->header.child_heartbeat, child_beat + 1);
  atomic_flag_clear(&context.watch_busy);
  return 0;
}

int fs_diag_child_finish(uint64_t id, int status) {
  if (!valid(id, FS_DIAG_ENDPOINT_CHILD) ||
      (status != 0 && status != 65 && status != 67) ||
      (status == 0 && !context.endpoint.retired))
    return FS_DIAG_SUPPORT_ERROR;
  _exit(status);
}

static int endpoint_valid(uint64_t id) {
  if (id != 1 || !(atomic_load(&context.status) & FS_DIAG_SUPPORT_PREPARED) ||
      (atomic_load(&context.status) & FS_DIAG_SUPPORT_FAILED))
    return 0;
  fs_diag_page *page = atomic_load(&context.page);
  return header_valid(page) &&
         memcmp(page->header.nonce, context.nonce, 32) == 0;
}

int fs_diag_support_send(uint64_t id, uint8_t type, uint64_t request_id,
                         uint32_t total_length, const uint8_t *chunk,
                         uint32_t chunk_length) {
  if (id != 1 || chunk_length > FS_DIAG_CHUNK_BYTES)
    return FS_DIAG_SUPPORT_ERROR;
  if (!endpoint_valid(id))
    return fail();
  if (context.role == FS_DIAG_ENDPOINT_PARENT && atomic_load(&context.cancel))
    return FS_DIAG_CHANNEL_ERROR;
  if (context.role == FS_DIAG_ENDPOINT_PARENT && type == FS_DIAG_INIT &&
      !(atomic_load(&context.status) & FS_DIAG_SUPPORT_WATCH_BOUND))
    return FS_DIAG_CHANNEL_EMPTY;
  return fs_diag_endpoint_send(&context.endpoint, type, request_id,
                               total_length, chunk, chunk_length);
}

int fs_diag_support_receive(uint64_t id, uint8_t *output, uint32_t capacity,
                            uint32_t *copied, uint8_t *type,
                            uint64_t *request_id, uint32_t *total_length) {
  if (copied == NULL || type == NULL || request_id == NULL ||
      total_length == NULL)
    return FS_DIAG_SUPPORT_ERROR;
  *copied = 0;
  *type = 0;
  *request_id = 0;
  *total_length = 0;
  if (id != 1 || capacity > FS_DIAG_CHUNK_BYTES)
    return FS_DIAG_SUPPORT_ERROR;
  if (!endpoint_valid(id))
    return fail();
  int result =
      fs_diag_endpoint_receive(&context.endpoint, output, capacity, copied);
  if (result == FS_DIAG_CHANNEL_COMPLETE) {
    *type = context.endpoint.receive.type;
    *request_id = context.endpoint.receive.request_id;
    *total_length = context.endpoint.receive.length;
    if (context.role == FS_DIAG_ENDPOINT_CHILD && *type == FS_DIAG_INIT)
      atomic_store(&context.init_received, 1);
  }
  return result;
}
