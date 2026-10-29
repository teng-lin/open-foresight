// The /proc scan against a fake /proc tree.
#include "zoom_linux_proc.h"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

using namespace foresight::zoom;

namespace {

int failures = 0;

void check(bool value, const std::string &what) {
  if (!value) {
    std::cerr << "FAIL: " << what << '\n';
    ++failures;
  }
}

void make_dir(const std::string &path, mode_t mode = 0700) {
  mkdir(path.c_str(), mode);
}

void add_process(const std::string &proc, int pid,
                 const std::string &exe_target) {
  make_dir(proc + "/" + std::to_string(pid));
  symlink(exe_target.c_str(),
          (proc + "/" + std::to_string(pid) + "/exe").c_str());
}

} // namespace

int main() {
  const char *root = std::getenv("FORESIGHT_TEST_TEMP_ROOT");
  if (!root || !*root)
    root = std::getenv("TMPDIR");
  std::string pattern =
      std::string(root && *root ? root : "/var/tmp") + "/zoomproc.XXXXXX";
  if (!mkdtemp(pattern.data())) {
    std::cerr << "cannot create a temporary directory\n";
    return 1;
  }
  const std::string dir = pattern, proc = dir + "/proc", install = dir + "/opt";
  make_dir(proc);
  make_dir(install);
  make_dir(install + "/zoom");
  {
    std::ofstream(install + "/zoom/version.txt") << "7.2.1.5760\nignored\n";
  }
  const uid_t me = geteuid();

  add_process(proc, 100, install + "/zoom/zoom"); // Zoom's main process
  add_process(proc, 101, install + "/zoom/ZoomWebviewHost"); // a helper process
  add_process(proc, 102, "/usr/bin/bash");                   // unrelated
  make_dir(proc + "/103");  // exited: no exe link
  make_dir(proc + "/self"); // not a pid
  {
    std::ofstream(proc + "/104");
  } // a file, not a directory
  ProcessScan scan = scan_zoom_processes(proc, "zoom", me);
  check(scan.ok && scan.processes.size() == 1 && scan.processes[0].pid == 100 &&
            scan.processes[0].version == "7.2.1.5760",
        "only the main process is found, with its version");

  // A replaced binary keeps its name with a " (deleted)" suffix.
  add_process(proc, 105, install + "/zoom/zoom (deleted)");
  scan = scan_zoom_processes(proc, "zoom", me);
  check(scan.ok && scan.processes.size() == 2,
        "a deleted executable still counts");

  // Another user's process is not ours to read.
  check(scan_zoom_processes(proc, "zoom", me + 1).processes.empty(),
        "processes of another uid are ignored");

  // A malformed version is empty, never a guess.
  make_dir(install + "/odd");
  {
    std::ofstream(install + "/odd/version.txt")
        << std::string(100, '9') << "\n";
  }
  add_process(proc, 106, install + "/odd/zoom");
  scan = scan_zoom_processes(proc, "zoom", me);
  bool saw_empty = false;
  for (const auto &p : scan.processes)
    saw_empty = saw_empty || (p.pid == 106 && p.version.empty());
  check(saw_empty, "an over-long version.txt line is unknown");

  // An unreadable directory is an unknown, not an absence.
  check(!scan_zoom_processes(dir + "/missing", "zoom", me).ok,
        "a missing /proc fails the scan");

  // A process whose directory this user may not search (EACCES on its exe link,
  // as for non-dumpable helpers) is skipped without failing the scan.
  if (me != 0) {
    add_process(proc, 107, install + "/zoom/zoom");
    chmod((proc + "/107").c_str(), 0600);
    scan = scan_zoom_processes(proc, "zoom", me);
    bool saw_denied = false;
    for (const auto &p : scan.processes)
      saw_denied = saw_denied || p.pid == 107;
    check(scan.ok && !saw_denied,
          "an uninspectable process is skipped, not a scan failure");
    chmod((proc + "/107").c_str(), 0700);
  }

  std::string cleanup = "rm -rf '" + dir + "'";
  if (system(cleanup.c_str()) != 0)
    std::cerr << "cleanup failed\n";
  std::cout << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
