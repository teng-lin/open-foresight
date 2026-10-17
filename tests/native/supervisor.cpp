#include "../../native/portable_process.h"
int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  return foresight::supervise_worker(argc, argv);
}
