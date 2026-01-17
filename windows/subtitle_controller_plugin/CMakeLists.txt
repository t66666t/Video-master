cmake_minimum_required(VERSION 3.14)
project(subtitle_controller_plugin LANGUAGES CXX)

set(PLUGIN_NAME "subtitle_controller_plugin")

add_library(${PLUGIN_NAME} SHARED
  subtitle_controller_plugin.cc
)

target_include_directories(${PLUGIN_NAME} PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
)

list(APPEND FLUTTER_PLUGIN_LIST ${PLUGIN_NAME})
