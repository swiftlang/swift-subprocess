add_library(Subprocess)

add_subdirectory(_SubprocessCShims)
add_subdirectory(Subprocess)

target_compile_options(Subprocess PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature StrictConcurrency>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature NonescapableTyeps>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature LifetimeDependence>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature Span>")

target_link_libraries(Subprocess PRIVATE SystemPackage)
