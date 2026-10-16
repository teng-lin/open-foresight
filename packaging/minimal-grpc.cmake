# Include after gRPC's project() via CMAKE_PROJECT_grpc_INCLUDE. Keep the full
# secure grpc/grpc++ implementation and C++ plugin; omit duplicate unsecure
# libraries and optional wrappers not used by Foresight. This does not disable
# insecure Unix-socket transport in the normal grpc library.
set(_FORESIGHT_UNUSED_GRPC_TARGETS
    grpc_unsecure grpc++_unsecure grpc++_alts grpc++_reflection
    grpc++_error_details grpc_authorization_provider grpcpp_channelz
    grpcpp_otel_plugin grpc_csharp_ext)

function(install)
  if(ARGV0 STREQUAL "TARGETS")
    foreach(_target IN LISTS _FORESIGHT_UNUSED_GRPC_TARGETS)
      if(ARGV1 STREQUAL _target)
        return()
      endif()
    endforeach()
  endif()
  _install(${ARGV})
endfunction()

function(_foresight_exclude_unused_grpc)
  foreach(_target IN LISTS _FORESIGHT_UNUSED_GRPC_TARGETS)
    if(TARGET "${_target}")
      set_target_properties("${_target}" PROPERTIES EXCLUDE_FROM_ALL TRUE)
    endif()
  endforeach()
endfunction()
cmake_language(DEFER CALL _foresight_exclude_unused_grpc)
