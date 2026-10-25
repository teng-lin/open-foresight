cmake_minimum_required(VERSION 3.24)
# Qualified SQL is compiled outside application directory/target/source/rule
# state. The caller supplies only the closed public cache vector below.
project(foresight_sql_support_product LANGUAGES C)
find_package(Threads REQUIRED)
if(NOT "${CMAKE_C_LINK_FLAGS}" STREQUAL "${SQL_PLATFORM_LINK_FLAGS}")
  message(FATAL_ERROR "SQL isolated platform recipe changed")
endif()
set(CMAKE_INCLUDE_CURRENT_DIR OFF)
set(CMAKE_INCLUDE_CURRENT_DIR_IN_INTERFACE OFF)
add_library(foresight_sql_support SHARED "${SQL_SOURCE_ROOT}/native/sql_support.c")
target_compile_options(foresight_sql_support PRIVATE ${SQL_COMPILE_OPTIONS})
target_compile_definitions(foresight_sql_support PRIVATE
  "FORESIGHT_SQL_SUPPORT_SOURCE_ID=\"${SQL_SOURCE_ID}\"")
target_link_libraries(foresight_sql_support PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
set_target_properties(foresight_sql_support PROPERTIES
  C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
  C_VISIBILITY_PRESET hidden POSITION_INDEPENDENT_CODE ON
  INTERPROCEDURAL_OPTIMIZATION OFF UNITY_BUILD OFF
  SKIP_BUILD_RPATH ON BUILD_RPATH "" INSTALL_RPATH ""
  LIBRARY_OUTPUT_DIRECTORY "${SQL_OUTPUT_DIRECTORY}"
  MACOSX_RPATH ON INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)
file(WRITE "${CMAKE_BINARY_DIR}/normalize.cmake"
  "file(CHMOD \"${SQL_OUTPUT_DIRECTORY}/${CMAKE_SHARED_LIBRARY_PREFIX}foresight_sql_support${CMAKE_SHARED_LIBRARY_SUFFIX}\" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)\n")
add_custom_command(TARGET foresight_sql_support POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -P "${CMAKE_BINARY_DIR}/normalize.cmake" VERBATIM)
