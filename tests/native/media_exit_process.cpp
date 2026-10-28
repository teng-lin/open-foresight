// Rename only this translation unit's waitid call. The separately compiled
// barrier delegates to the real kernel API; shipped code is unchanged.
#define waitid media_exit_barrier_waitid
#include "../../native/media_process.cpp"
