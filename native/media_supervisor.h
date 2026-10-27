#pragma once
namespace foresight {
// Internal argv comes only from the pinned native launcher, never RPC options.
int media_supervisor_main(int argc, char **argv, const char *build_id);
} // namespace foresight
