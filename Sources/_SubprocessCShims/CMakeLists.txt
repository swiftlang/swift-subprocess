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

add_library(_SubprocessCShims STATIC
  process_shims.c)
target_include_directories(_SubprocessCShims PUBLIC
  include)

# For dlsym, used to detect posix_spawn file actions that some libc versions
# lack. Empty on platforms where dlsym lives in libc.
target_link_libraries(_SubprocessCShims PRIVATE ${CMAKE_DL_LIBS})

install(TARGETS _SubprocessCShims
  EXPORT SwiftSubprocessTargets)
