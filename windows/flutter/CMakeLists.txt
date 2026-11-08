# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.14)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

# Configuration provided via flutter tool.
if(NOT DEFINED FLUTTER_TARGET_PLATFORM)
  set(FLUTTER_TARGET_PLATFORM "windows-x64")
endif()

# Include the wrapper that connects to the Flutter engine library.
include("${EPHEMERAL_DIR}/generated_config.cmake" OPTIONAL)

# Standard settings function in case generated_config.cmake is not available.
if(NOT COMMAND apply_standard_settings)
  function(apply_standard_settings TARGET)
    target_compile_features(${TARGET} PUBLIC cxx_std_17)
    target_compile_options(${TARGET} PRIVATE /W4 /WX /EHsc)
    target_compile_definitions(${TARGET} PRIVATE "_UNICODE" "UNICODE")
    target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
  endfunction()
endif()

# === Flutter Wrapper ===
set(FLUTTER_WRAPPER_ROOT "${EPHEMERAL_DIR}/cpp_client_wrapper")

# === Flutter Tooling ===
set(FLUTTER_LIBRARY "${EPHEMERAL_DIR}/flutter_windows.dll")
set(FLUTTER_LIBRARY ${FLUTTER_LIBRARY} PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${EPHEMERAL_DIR}/icudtl.dat")
set(FLUTTER_ICU_DATA_FILE ${FLUTTER_ICU_DATA_FILE} PARENT_SCOPE)
set(PROJECT_BUILD_DIR "${PROJECT_DIR}/build/windows")
set(PROJECT_BUILD_DIR ${PROJECT_BUILD_DIR} PARENT_SCOPE)

# The list of sources for the library.
set(WRAPPER_ROOT "${FLUTTER_WRAPPER_ROOT}")
set(WRAPPER_SOURCES
  "${WRAPPER_ROOT}/client_wrapper_subclass.cc"
  "${WRAPPER_ROOT}/flutter_engine.cc"
  "${WRAPPER_ROOT}/flutter_view_controller.cc"
)

# Wrapper library that provides C++ classes for interacting with the engine.
add_library(flutter_wrapper_app STATIC
  ${WRAPPER_SOURCES}
  "${WRAPPER_ROOT}/standard_codec.cc"
  "${WRAPPER_ROOT}/plugin_registrar.cc"
)
apply_standard_settings(flutter_wrapper_app)
set_target_properties(flutter_wrapper_app PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
set_target_properties(flutter_wrapper_app PROPERTIES
  CXX_VISIBILITY_PRESET "hidden"
  VISIBILITY_INLINES_HIDDEN ON
)
target_link_libraries(flutter_wrapper_app PUBLIC "${EPHEMERAL_DIR}/flutter_windows.dll.lib")
target_include_directories(flutter_wrapper_app PUBLIC
  "${EPHEMERAL_DIR}"
  "${WRAPPER_ROOT}/include"
)
add_dependencies(flutter_wrapper_app flutter_assemble)

# Wrapper library that provides C++ classes for plugins to use.
add_library(flutter_wrapper_plugin STATIC
  ${WRAPPER_SOURCES}
  "${WRAPPER_ROOT}/standard_codec.cc"
  "${WRAPPER_ROOT}/plugin_registrar.cc"
)
apply_standard_settings(flutter_wrapper_plugin)
set_target_properties(flutter_wrapper_plugin PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
set_target_properties(flutter_wrapper_plugin PROPERTIES
  CXX_VISIBILITY_PRESET "hidden"
  VISIBILITY_INLINES_HIDDEN ON
)
target_link_libraries(flutter_wrapper_plugin PUBLIC "${EPHEMERAL_DIR}/flutter_windows.dll.lib")
target_include_directories(flutter_wrapper_plugin PUBLIC
  "${EPHEMERAL_DIR}"
  "${WRAPPER_ROOT}/include"
)
add_dependencies(flutter_wrapper_plugin flutter_assemble)

# === Flutter Assemble ===
# Target that checks if the assets and engine need to be regenerated, and runs
# the Flutter tooling if so.
add_custom_target(flutter_assemble
  COMMAND ${CMAKE_COMMAND} -E echo "Building Flutter assets and engine..."
)
