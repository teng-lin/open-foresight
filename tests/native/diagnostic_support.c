#define _POSIX_C_SOURCE 200809L
#include "diagnostic_support.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include "diagnostic_protocol.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef FORESIGHT_DIAGNOSTIC_NATIVE_ID
#error Fixture native identity required
#endif
static const char identity[] = FORESIGHT_DIAGNOSTIC_NATIVE_ID;
static atomic_int watcher_started;

static void tick(void) {
  struct timespec delay = {0, 10000000};
  nanosleep(&delay, NULL);
}

static void *watcher(void *unused) {
  (void)unused;
  for (;;) {
    assert(fs_diag_child_watch(1) == 0);
    atomic_store(&watcher_started, 1);
    tick();
  }
  return NULL;
}

static int receive(uint8_t expected_type, uint64_t expected_id, int parent) {
  for (int i = 0; i != 200; ++i) {
    uint8_t bytes[128], type;
    uint64_t id;
    uint32_t copied, total;
    int result = fs_diag_support_receive(1, bytes, sizeof(bytes), &copied,
                                         &type, &id, &total);
    assert(result != FS_DIAG_CHANNEL_ERROR);
    if (result == FS_DIAG_CHANNEL_COMPLETE) {
      assert(type == expected_type && id == expected_id);
      if (expected_type == FS_DIAG_INIT || expected_type == FS_DIAG_RESULT) {
        assert(total == 4 && copied == 4);
        assert(memcmp(bytes, "test", 4) == 0);
      } else {
        assert(total == 0 && copied == 0);
      }
      return 1;
    }
    if (parent)
      assert(fs_diag_parent_heartbeat(1) == 0);
    tick();
  }
  return 0;
}

static int worker(const char *parent_text, const char *mode) {
  int hold = strcmp(mode, "hold") == 0 || strcmp(mode, "deadline") == 0;
  int wrong_identity = strcmp(mode, "wrong-identity") == 0;
  char other[65];
  memcpy(other, identity, 65);
  other[0] = other[0] == '0' ? '1' : '0';
  assert(fs_diag_child_arm(strtol(parent_text, NULL, 10), identity,
                           wrong_identity ? other : identity, identity) == 1);
  pthread_t thread;
  assert(pthread_create(&thread, NULL, watcher, NULL) == 0);
  while (!atomic_load(&watcher_started))
    tick();
  if (strcmp(mode, "bootstrap") == 0)
    for (;;)
      pause();
  int mapped = fs_diag_child_map(1);
  if (wrong_identity) {
    assert(mapped == FS_DIAG_SUPPORT_ERROR);
    for (;;)
      pause();
  }
  assert(mapped == FS_DIAG_SUPPORT_PREPARED);
  assert(fs_diag_support_send(1, FS_DIAG_HELLO, 0, 0, NULL, 0) ==
         FS_DIAG_CHANNEL_COMPLETE);
  assert(receive(FS_DIAG_INIT, 1, 0));
  assert(fs_diag_support_send(1, FS_DIAG_RESULT, 1, 4, (const uint8_t *)"test",
                              4) == FS_DIAG_CHANNEL_COMPLETE);
  if (hold) {
    // A real blocked main thread; independent watcher must still acknowledge
    // FORCE and terminate the process. This is not yet the Dart isolate test.
    assert(fs_diag_child_operation(1, 1) == 0);
    for (;;)
      pause();
  }
  assert(receive(FS_DIAG_RETIRE, 2, 0));
  assert(fs_diag_support_send(1, FS_DIAG_RETIRED, 2, 0, NULL, 0) ==
         FS_DIAG_CHANNEL_COMPLETE);
  return 0;
}

static void run_case(const char *launcher, const char *self, const char *mode) {
  alarm(10);
  char parent[24], arguments[2048];
  snprintf(parent, sizeof(parent), "%ld", (long)getpid());
  const char *items[] = {launcher,   identity, parent, self,
                         "--worker", parent,   mode,   NULL};
  uint32_t length = 0;
  for (unsigned i = 0; items[i] != NULL; ++i) {
    size_t count = strlen(items[i]) + 1;
    assert(length + count <= sizeof(arguments));
    memcpy(arguments + length, items[i], count);
    length += (uint32_t)count;
  }
  int bad = strcmp(mode, "bad-argv") == 0;
  assert(fs_diag_parent_reserve(identity, identity, identity,
                                (uint8_t *)arguments, length - (bad ? 1 : 0),
                                7) == (uint64_t)(bad ? 0 : 1));
  // Even an invalid or finished first attempt cannot allocate another context.
  assert(fs_diag_parent_reserve(identity, identity, identity,
                                (uint8_t *)arguments, length, 7) == 0);
  if (bad)
    return;
  assert(fs_diag_parent_prepare(2) == FS_DIAG_SUPPORT_ERROR);
  if (strcmp(mode, "cancel-before") == 0) {
    assert(fs_diag_parent_force(1) == FS_DIAG_SUPPORT_CANCELLED);
    assert(fs_diag_parent_prepare(1) == FS_DIAG_SUPPORT_CANCELLED);
    assert(fs_diag_parent_spawn(1) == FS_DIAG_SUPPORT_ERROR);
    return;
  }
  assert(fs_diag_parent_prepare(1) == FS_DIAG_SUPPORT_PREPARED);
  assert(fs_diag_parent_prepare(1) == FS_DIAG_SUPPORT_ERROR);
  if (strcmp(mode, "cancel-prepared") == 0) {
    assert(fs_diag_parent_force(1) == FS_DIAG_SUPPORT_CANCELLED);
    assert(fs_diag_parent_spawn(1) == FS_DIAG_SUPPORT_CANCELLED);
    assert(!(fs_diag_parent_poll(1) & FS_DIAG_SUPPORT_SPAWNED));
    return;
  }
  assert(fs_diag_parent_spawn(1) == FS_DIAG_SUPPORT_SPAWNED);
  assert(fs_diag_parent_spawn(1) == FS_DIAG_SUPPORT_ERROR);
  if (strcmp(mode, "wrong-identity") != 0 && strcmp(mode, "bootstrap") != 0) {
    assert(receive(FS_DIAG_HELLO, 0, 1));
    // HELLO alone cannot admit private INIT before the coordinator observes
    // the fresh post-registration challenge acknowledgement.
    assert(fs_diag_support_send(1, FS_DIAG_INIT, 1, 4, (const uint8_t *)"test",
                                4) == FS_DIAG_CHANNEL_EMPTY);
    int bound = 0;
    for (int i = 0; i != 100; ++i) {
      if (fs_diag_parent_poll(1) & FS_DIAG_SUPPORT_WATCH_BOUND) {
        bound = 1;
        break;
      }
      tick();
    }
    assert(bound);
    assert(fs_diag_support_send(1, FS_DIAG_INIT, 1, 4, (const uint8_t *)"test",
                                4) == FS_DIAG_CHANNEL_COMPLETE);
    assert(receive(FS_DIAG_RESULT, 1, 1));
    if (strcmp(mode, "hold") == 0) {
      // FORCE is serviced by the independent watcher while main is blocked.
      assert(fs_diag_parent_force(1) == FS_DIAG_SUPPORT_CANCELLED);
    } else if (strcmp(mode, "deadline") != 0) {
      assert(fs_diag_support_send(1, FS_DIAG_RETIRE, 2, 0, NULL, 0) ==
             FS_DIAG_CHANNEL_COMPLETE);
      assert(receive(FS_DIAG_RETIRED, 2, 1));
    }
  }
  int status = 0;
  int unbound_case =
      strcmp(mode, "wrong-identity") == 0 || strcmp(mode, "bootstrap") == 0;
  int polls = strcmp(mode, "deadline") == 0 ? 650 : unbound_case ? 120 : 100;
  for (int i = 0; i != polls; ++i) {
    status = fs_diag_parent_poll(1);
    assert(status >= 0);
    if (status & FS_DIAG_SUPPORT_NOT_LIVE)
      break;
    // Expiry must work while the parent/heartbeat remain responsive, so this
    // cannot pass accidentally through the heartbeat lease instead.
    if (strcmp(mode, "deadline") == 0)
      assert(fs_diag_parent_heartbeat(1) == 0);
    tick();
  }
#ifdef __APPLE__
  // Rejected identity cannot ACK/bind the Darwin watch. Its finite process
  // exit is proven only by this test harness's actual wait, not parent_poll.
  if (strcmp(mode, "wrong-identity") != 0 && strcmp(mode, "bootstrap") != 0)
    assert(status & FS_DIAG_SUPPORT_NOT_LIVE);
  assert(!(status & FS_DIAG_SUPPORT_REAPED));
  int actual;
  assert(wait(&actual) > 0);
  assert(WIFEXITED(actual));
  int expected = strcmp(mode, "bootstrap") == 0 ? 65
                 : strcmp(mode, "hold") == 0 || strcmp(mode, "deadline") == 0
                     ? 66
                 : strcmp(mode, "wrong-identity") == 0 ? 67
                                                       : 0;
  assert(WEXITSTATUS(actual) == expected);
#else
  assert(status & FS_DIAG_SUPPORT_NOT_LIVE);
  assert(status & FS_DIAG_SUPPORT_REAPED);
  int expected = strcmp(mode, "bootstrap") == 0 ? FS_DIAG_EXIT_BOOTSTRAP
                 : strcmp(mode, "hold") == 0 || strcmp(mode, "deadline") == 0
                     ? FS_DIAG_EXIT_RETIREMENT
                 : strcmp(mode, "wrong-identity") == 0 ? FS_DIAG_EXIT_UNSAFE
                                                       : FS_DIAG_EXIT_NORMAL;
  assert(fs_diag_parent_exit_class(1) == expected);
#endif
}

int main(int argc, char **argv) {
  // Actual launcher argv becomes self,--worker,parent,mode (four entries).
  if (argc == 4 && strcmp(argv[1], "--worker") == 0)
    return worker(argv[2], argv[3]);
  assert(argc == 3);
#ifdef FS_DIAG_FIXTURE_BASE
  assert(mkdir(FS_DIAG_FIXTURE_BASE, 0700) == 0 || errno == EEXIST);
#endif
  alarm(20);
  const char *cases[] = {"normal",    "hold",          "wrong-identity",
                         "bad-argv",  "cancel-before", "cancel-prepared",
                         "bootstrap", "deadline"};
  for (unsigned i = 0; i != sizeof(cases) / sizeof(cases[0]); ++i) {
    fprintf(stderr, "diagnostic support case: %s\n", cases[i]);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
      run_case(argv[1], argv[2], cases[i]);
      _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      fprintf(stderr, "diagnostic support case %s failed: %d\n", cases[i],
              status);
      return 1;
    }
  }
  puts("diagnostic support: 8 actual-process cases passed");
  return 0;
}
