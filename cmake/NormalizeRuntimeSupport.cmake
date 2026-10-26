cmake_minimum_required(VERSION 3.20)
if(IS_SYMLINK "${SQL_PRODUCT}" OR NOT EXISTS "${SQL_PRODUCT}" OR IS_DIRECTORY "${SQL_PRODUCT}")
  message(FATAL_ERROR "SQL linked product unavailable")
endif()
# User-private-group umasks must not turn freshly linked code into a mutable
# runtime artifact. Normalize only the explicit completed product, before hash.
file(CHMOD "${SQL_PRODUCT}" PERMISSIONS
  OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
