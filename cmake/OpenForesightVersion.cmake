# Reads the release version from apps/desktop/pubspec.yaml, the single source of truth.
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/../apps/desktop/pubspec.yaml" _open_foresight_version_line
  REGEX "^version: [0-9]+\\.[0-9]+\\.[0-9]+\\+[0-9]+$")
if(NOT _open_foresight_version_line)
  message(FATAL_ERROR "apps/desktop/pubspec.yaml must declare \"version: X.Y.Z+N\"")
endif()
string(REGEX REPLACE "^version: ([0-9.]+)\\+([0-9]+)$" "\\1" OPEN_FORESIGHT_VERSION "${_open_foresight_version_line}")
string(REGEX REPLACE "^version: ([0-9.]+)\\+([0-9]+)$" "\\2" OPEN_FORESIGHT_BUILD_NUMBER "${_open_foresight_version_line}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_LIST_DIR}/../apps/desktop/pubspec.yaml")
