target_sources(Subprocess PRIVATE process_shims.c)

target_include_directories(Subprocess PRIVATE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>")
