cmake_minimum_required(VERSION 3.29)
project(Subprocess LANGUAGES C Swift)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")

add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:SHELL:-package-name ${PROJECT_NAME}>")

include(InstallExternalDependencies)

add_subdirectory(Sources)
