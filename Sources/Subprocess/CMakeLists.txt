##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2025 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
##
##===----------------------------------------------------------------------===##

add_library(Subprocess
  Execution.swift
  Buffer.swift
  Error.swift
  Teardown.swift
  Thread.swift
  Result.swift
  IO/Output.swift
  IO/Input.swift
  IO/AsyncIO+Dispatch.swift
  IO/AsyncIO+Linux.swift
  IO/AsyncIO+Windows.swift
  Span+Subprocess.swift
  AsyncBufferSequence.swift
  API.swift
  SubprocessFoundation/Span+SubprocessFoundation.swift
  SubprocessFoundation/Output+Foundation.swift
  SubprocessFoundation/Input+Foundation.swift
  Configuration.swift)
if(WIN32)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+Windows.swift)
elseif(LINUX OR ANDROID)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+Linux.swift
    Platforms/Subprocess+Unix.swift)
elseif(APPLE)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+BSD.swift
    Platforms/Subprocess+Darwin.swift
    Platforms/Subprocess+Unix.swift)
elseif(FREEBSD OR OPENBSD)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+BSD.swift
    Platforms/Subprocess+Unix.swift)
endif()

target_compile_options(Subprocess PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature StrictConcurrency>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature NonescapableTyeps>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature LifetimeDependence>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature Span>")
target_link_libraries(Subprocess PUBLIC
  _SubprocessCShims)
target_link_libraries(Subprocess PRIVATE
  SwiftSystem::SystemPackage)

install(TARGETS Subprocess
  EXPORT SwiftSubprocessTargets
  ARCHIVE DESTINATION "${${PROJECT_NAME}_INSTALL_LIBDIR}"
  LIBRARY DESTINATION "${${PROJECT_NAME}_INSTALL_LIBDIR}"
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
emit_swift_interface(Subprocess)
install_swift_interface(Subprocess)
