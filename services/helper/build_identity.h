#pragma once

// Keep volatile source metadata outside the helper implementation so that a
// Dart-only commit does not recompile the helper's expensive translation unit.
const char *foresight_helper_build_id();
