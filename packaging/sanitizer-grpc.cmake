# Keep the normal release SDK target selection, then remove one upstream source
# duplication exposed by ASan's global ODR checks in the shared-library build.
include("${CMAKE_CURRENT_LIST_DIR}/minimal-grpc.cmake")

function(_foresight_share_upb_descriptor)
  # gRPC compiles this file into libgrpc as well as libupb_descriptor_lib, which
  # is linked through upb_json_lib. Use the latter's single instrumented copy.
  set(_descriptor src/core/ext/upb-gen/google/protobuf/descriptor.upb_minitable.c)
  get_target_property(_sources grpc SOURCES)
  list(FIND _sources "${_descriptor}" _index)
  if(_index EQUAL -1)
    message(FATAL_ERROR "Pinned gRPC descriptor source changed; review sanitizer deduplication")
  endif()
  list(REMOVE_ITEM _sources "${_descriptor}")
  set_property(TARGET grpc PROPERTY SOURCES "${_sources}")
  target_link_libraries(grpc upb_descriptor_lib)
endfunction()
cmake_language(DEFER CALL _foresight_share_upb_descriptor)
