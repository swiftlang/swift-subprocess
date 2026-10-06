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

include_guard()

# Locates (or, if allowed, fetches) the external dependencies of Subprocess.
#
# swift-system's SystemPackage module is only used on non-Apple platforms;
# Apple platforms use the System framework from the SDK instead.
#
# Toolchain and other integrated builds are expected to provide dependencies
# via `<Pkg>_DIR`. A dependency that is not found is fetched from the network
# only when `Subprocess_VENDOR_DEPENDENCIES` is enabled and no explicit
# `<Pkg>_DIR` was given; otherwise configuration fails with a diagnostic.

if(NOT APPLE)
  # If the dependency location was given explicitly, never fall back to
  # fetching it: a wrong path should be an error, not a silent download.
  if(SwiftSystem_DIR)
    set(_Subprocess_SwiftSystem_DIR_explicit YES)
  endif()

  find_package(SwiftSystem CONFIG QUIET)
  if(SwiftSystem_FOUND)
    message(STATUS "Using swift-system from ${SwiftSystem_DIR}")
    set(${PROJECT_NAME}_SwiftSystem_DIR "${SwiftSystem_DIR}")
  elseif(_Subprocess_SwiftSystem_DIR_explicit)
    message(FATAL_ERROR
      "swift-system was not found in the explicitly provided SwiftSystem_DIR. "
      "Set SwiftSystem_DIR to the directory containing SwiftSystemConfig.cmake "
      "(e.g. <swift-system build>/cmake/modules).")
  elseif(${PROJECT_NAME}_VENDOR_DEPENDENCIES)
    message(STATUS "Vendoring swift-system (SwiftSystem_DIR not set; pass "
      "-D${PROJECT_NAME}_VENDOR_DEPENDENCIES=OFF to disable fetching)")
    include(FetchContent)
    FetchContent_Declare(SwiftSystem
      GIT_REPOSITORY https://github.com/apple/swift-system.git
      GIT_TAG 61e4ca4b81b9e09e2ec863b00c340eb13497dac6 # 1.5.0
      GIT_SHALLOW YES)
    FetchContent_MakeAvailable(SwiftSystem)
    if(NOT TARGET SwiftSystem::SystemPackage)
      add_library(SwiftSystem::SystemPackage ALIAS SystemPackage)
    endif()
    set(${PROJECT_NAME}_SwiftSystem_DIR "${swiftsystem_BINARY_DIR}/cmake/modules")
  else()
    message(FATAL_ERROR
      "swift-system is required on this platform but was not found, and "
      "${PROJECT_NAME}_VENDOR_DEPENDENCIES is OFF. Set SwiftSystem_DIR to the "
      "directory containing SwiftSystemConfig.cmake (e.g. "
      "<swift-system build>/cmake/modules), or enable "
      "${PROJECT_NAME}_VENDOR_DEPENDENCIES to fetch it.")
  endif()
endif()

if(${PROJECT_NAME}_ENABLE_FOUNDATION AND NOT APPLE)
  # On non-Apple platforms, SubprocessFoundation imports FoundationEssentials.
  # Toolchains and SDKs provide it implicitly. An explicitly provided Foundation
  # package (Foundation_DIR, e.g. a swift-corelibs-foundation build tree) is
  # used when available, matching other swiftlang CMake projects.
  find_package(Foundation CONFIG QUIET)
  if(TARGET FoundationEssentials)
    message(STATUS "Using FoundationEssentials from ${Foundation_DIR}")
    set(${PROJECT_NAME}_Foundation_DIR "${Foundation_DIR}")
  endif()
endif()
