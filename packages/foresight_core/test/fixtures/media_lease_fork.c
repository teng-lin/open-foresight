// Test-only single-threaded process. The post-fork branch uses only
// async-signal-safe operations before exec; Dart never calls fork.
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#define _DEFAULT_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  alarm(15);
  if (argc == 5 && strcmp(argv[1], "--exec-child") == 0) {
    int lease = atoi(argv[2]), command = atoi(argv[3]), ready = atoi(argv[4]);
    int flags = fcntl(lease, F_GETFD);
    if (flags < 0)
      assert(errno == EBADF);
    char c = flags >= 0 ? 'O' : 'X';
    assert(write(ready, &c, 1) == 1);
    assert(read(command, &c, 1) == 1 && c == 'Q');
    return 0;
  }
  assert(argc == 3);
  int retained = strcmp(argv[2], "retained") == 0;
  int lease = open(argv[1], O_RDWR | O_CLOEXEC);
  assert(lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0);
  int command[2], ready[2];
  assert(pipe(command) == 0 && pipe(ready) == 0);
  char lease_s[32], command_s[32], ready_s[32];
  snprintf(lease_s, sizeof lease_s, "%d", lease);
  snprintf(command_s, sizeof command_s, "%d", command[0]);
  snprintf(ready_s, sizeof ready_s, "%d", ready[1]);
  pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    close(command[1]);
    close(ready[0]);
    char c;
    if (write(ready[1], "F", 1) != 1 || read(command[0], &c, 1) != 1)
      _exit(90);
    if (c == 'Q')
      _exit(0);
    if (c != 'E')
      _exit(91);
    if (retained && fcntl(lease, F_SETFD, 0) != 0)
      _exit(92);
    execl(argv[0], argv[0], "--exec-child", lease_s, command_s, ready_s,
          (char *)NULL);
    _exit(93);
  }
  close(command[0]);
  close(ready[1]);
  char c;
  assert(read(ready[0], &c, 1) == 1 && c == 'F');
  close(lease);
  puts("forked");
  fflush(stdout);
  while (read(STDIN_FILENO, &c, 1) == 1 && c != 'Q') {
    assert(c == 'E' && write(command[1], &c, 1) == 1);
    assert(read(ready[0], &c, 1) == 1 && c == (retained ? 'O' : 'X'));
    assert(waitpid(child, NULL, WNOHANG) == 0);
    puts(retained ? "exec held alive" : "exec closed alive");
    fflush(stdout);
  }
  assert(write(command[1], "Q", 1) == 1);
  int status;
  assert(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
         WEXITSTATUS(status) == 0);
  puts("exited");
  return 0;
}
