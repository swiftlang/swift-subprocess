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

function(emit_swift_interface target)
  # Generate the target-variant binary swift module when performing zippered
  # build
  #
  # Clean this up once CMake has nested swiftmodules in the build directory:
  # https://gitlab.kitware.com/cmake/cmake/-/merge_requests/10664
  # https://cmake.org/cmake/help/git-stage/policy/CMP0195.html

  # We can't expand the Swift_MODULE_NAME target property in a generator
  # expression or it will fail saying that the target doesn't exist.
  get_target_property(module_name ${target} Swift_MODULE_NAME)
  if(NOT module_name)
    set(module_name ${target})
  endif()

  # Account for an existing swiftmodule file generated with the previous logic
  if(EXISTS "${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule"
     AND NOT IS_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule")
    message(STATUS "Removing regular file ${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule to support nested swiftmodule generation")
    file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule")
  endif()

  set(module_path "${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule/${${PROJECT_NAME}_MODULE_TRIPLE}.swiftmodule")

  # Have CMake itself emit the module at the nested path, rather than passing a
  # second `-emit-module-path` alongside the one CMake always adds. With two
  # module paths, the compiler honors whichever comes last, which depends on
  # where CMake places its own flag relative to the target's compile options
  # (CMake's development branch, for example, now appends it afterwards). If
  # CMake's path wins, a regular `<module>.swiftmodule` file is written where
  # the nested directory is expected, and clients fail with "Cannot find source
  # file" for the path below. Setting the module path properties makes both
  # agree, and also makes CMake create the parent directory and track the
  # module as a build output.
  set_target_properties(${target} PROPERTIES
    Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
  set(cmp0195 OLD)
  if(POLICY CMP0195)
    cmake_policy(GET CMP0195 cmp0195)
  endif()
  if(cmp0195 STREQUAL "NEW")
    # CMake nests the module under the triple itself.
    set_target_properties(${target} PROPERTIES
      Swift_MODULE "${module_name}.swiftmodule")
    set(CMAKE_Swift_MODULE_TRIPLE "${${PROJECT_NAME}_MODULE_TRIPLE}" PARENT_SCOPE)
  else()
    set_target_properties(${target} PROPERTIES
      Swift_MODULE "${module_name}.swiftmodule/${${PROJECT_NAME}_MODULE_TRIPLE}.swiftmodule")
  endif()

  set_source_files_properties("${module_path}" PROPERTIES GENERATED TRUE)
  target_sources(${target}
    INTERFACE
      $<BUILD_INTERFACE:${module_path}>)

  set_target_properties(${target} PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_CURRENT_BINARY_DIR})

  # Generate textual swift interfaces is library-evolution is enabled
  if(${PROJECT_NAME}_ENABLE_LIBRARY_EVOLUTION)
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:Swift>:-emit-module-interface-path$<SEMICOLON>${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule/${${PROJECT_NAME}_MODULE_TRIPLE}.swiftinterface>
      $<$<COMPILE_LANGUAGE:Swift>:-emit-private-module-interface-path$<SEMICOLON>${CMAKE_CURRENT_BINARY_DIR}/${module_name}.swiftmodule/${${PROJECT_NAME}_MODULE_TRIPLE}.private.swiftinterface>)
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:Swift>:-library-level$<SEMICOLON>api>
      $<$<COMPILE_LANGUAGE:Swift>:-Xfrontend$<SEMICOLON>-require-explicit-availability=ignore>)
  endif()
endfunction()
