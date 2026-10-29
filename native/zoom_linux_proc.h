#pragma once
// Finds the user's Zoom main process by scanning a /proc-style directory. Plain
// POSIX and no accessibility library, so it runs against a fake /proc in tests.
#include "zoom_linux_source.h"

#include <string>
#include <sys/types.h>

namespace foresight::zoom {

// Processes of `uid` whose executable's basename is `executable_name` (a
// " (deleted)" suffix on the link target is ignored). The version is the first
// line of `version.txt` beside the executable, empty when missing or malformed.
//
// A process that vanished (ENOENT/ENOTDIR/ESRCH) or that this user may not
// inspect (EACCES/EPERM: non-dumpable helpers, sandboxes) cannot be Zoom's main
// process and is skipped. Any other failure, or an unreadable directory, makes
// the scan `ok = false`: Zoom's absence is unknown, not established.
ProcessScan scan_zoom_processes(const std::string &proc_root,
                                const std::string &executable_name, uid_t uid);

// The entries of a D-Bus address list the helper will connect to: `unix:`
// transports only. `autolaunch:` could start a bus and `unixexec:` runs a
// program, neither of which a passive reader may do; other entries are dropped.
// Empty when none remains.
std::string safe_session_bus_address(const std::string &configured);

} // namespace foresight::zoom
