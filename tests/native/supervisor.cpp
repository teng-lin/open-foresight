#include "../../native/portable_process.h"
int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
#ifdef __APPLE__
  return foresight::supervise_worker(argc, argv);
#else
  return 1;
#endif
}
