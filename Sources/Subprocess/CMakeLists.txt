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
  IO/AsyncIO+KQueue.swift
  IO/AsyncIO+Linux.swift
  IO/AsyncIO+Windows.swift
  IO/AsyncIO+Unix.swift
  Span+Subprocess.swift
  SubprocessOutputSequence.swift
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
    Platforms/Subprocess+Spawn.swift
    Platforms/Subprocess+Unix.swift)
elseif(APPLE)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+BSD.swift
    Platforms/Subprocess+Darwin.swift
    Platforms/Subprocess+Spawn.swift
    Platforms/Subprocess+Unix.swift)
  target_compile_options(Subprocess PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-DSUBPROCESS_ASYNCIO_KQUEUE>")
elseif(FREEBSD OR OPENBSD)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+BSD.swift
    Platforms/Subprocess+Spawn.swift
    Platforms/Subprocess+Unix.swift)
  target_compile_options(Subprocess PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-DSUBPROCESS_ASYNCIO_KQUEUE>")
endif()

# Keep in sync with the Subprocess target's swiftSettings in Package.swift.
set_target_properties(Subprocess PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_compile_options(Subprocess PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature StrictConcurrency>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-experimental-feature Lifetimes>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature NonisolatedNonsendingByDefault>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature ExistentialAny>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature MemberImportVisibility>"
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature InternalImportsByDefault>")
if(${PROJECT_NAME}_ENABLE_FOUNDATION)
  # Equivalent of SwiftPM's (default) SubprocessFoundation trait.
  target_compile_options(Subprocess PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-DSubprocessFoundation>")
  if(NOT APPLE AND TARGET FoundationEssentials)
    target_link_libraries(Subprocess PUBLIC
      FoundationEssentials)
  endif()
endif()
target_link_libraries(Subprocess PUBLIC
  _SubprocessCShims)
if(NOT APPLE)
  # SystemPackage types (FilePath, FileDescriptor, ...) are part of the public
  # API on non-Apple platforms (`public import SystemPackage`), so clients need
  # its module and link information. Apple platforms use the System framework.
  target_link_libraries(Subprocess PUBLIC
    SwiftSystem::SystemPackage)
endif()

install(TARGETS Subprocess
  EXPORT SwiftSubprocessTargets
  ARCHIVE DESTINATION "${${PROJECT_NAME}_INSTALL_LIBDIR}"
  LIBRARY DESTINATION "${${PROJECT_NAME}_INSTALL_LIBDIR}"
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
emit_swift_interface(Subprocess)
install_swift_interface(Subprocess)
