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

cmake_minimum_required(VERSION 3.26...3.29)
project(Subprocess LANGUAGES C Swift)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")

add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:SHELL:-package-name ${PROJECT_NAME}>")

include(InstallExternalDependencies)

add_subdirectory(Sources)
