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

include(FetchContent)

find_package(SwiftSystem QUIET)
if(NOT SwiftSystem_FOUND)
  message("-- Vendoring swift-system")
  FetchContent_Declare(SwiftSystem
    GIT_REPOSITORY https://github.com/apple/swift-system.git
    GIT_TAG a34201439c74b53f0fd71ef11741af7e7caf01e1 # 1.4.2
    GIT_SHALLOW YES)
  list(APPEND VendoredDependencies SwiftSystem)
endif()

if(VendoredDependencies)
  FetchContent_MakeAvailable(${VendoredDependencies})
  if(NOT TARGET SwiftSystem::SystemPackage)
    add_library(SwiftSystem::SystemPackage ALIAS SystemPackage)
  endif()
endif()
