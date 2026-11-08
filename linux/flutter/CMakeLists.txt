# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.10)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

# Configuration provided via flutter tool.
include(${EPHEMERAL_DIR}/generated_config.cmake OPTIONAL)

# Set handling of build modes in the engine.
set(ENGINE_DEBUG_COPY_UBLIBCXX FALSE)
set(ENGINE_RELEASE_COPY_UBLIBCXX FALSE)
set(ENGINE_PROFILE_COPY_UBLIBCXX FALSE)
set(ENGINE_ARM_COPY_UBLIBCXX FALSE)

# Standard settings function in case generated_config.cmake is not available.
if(NOT COMMAND apply_standard_settings)
  function(apply_standard_settings TARGET)
    target_compile_features(${TARGET} PUBLIC cxx_std_17)
    target_compile_options(${TARGET} PRIVATE -Wall -Werror)
    target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
    target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
  endfunction()
endif()

# === Flutter Tooling ===
set(FLUTTER_ENGINE_DIR "${EPHEMERAL_DIR}")
set(FLUTTER_LIBRARY "${FLUTTER_ENGINE_DIR}/libflutter_linux_gtk.so")
set(FLUTTER_LIBRARY ${FLUTTER_LIBRARY} PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${FLUTTER_ENGINE_DIR}/icudtl.dat")
set(FLUTTER_ICU_DATA_FILE ${FLUTTER_ICU_DATA_FILE} PARENT_SCOPE)

# Flutter-managed assets directory.
set(FLUTTER_ASSETS_DIR "${PROJECT_BINARY_DIR}/flutter_assets")
set(FLUTTER_ASSETS_DIR ${FLUTTER_ASSETS_DIR} PARENT_SCOPE)

# The install-time library path to use for the Flutter library.
set(INSTALL_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

# === Target to assemble assets and binaries ===
# Target that checks if the assets and engine need to be regenerated, and runs
# the Flutter tooling if so.
add_custom_target(flutter_assemble
  COMMAND ${CMAKE_COMMAND} -E echo "Building Flutter assets and engine..."
)

# Target for Flutter engine library.
if(EXISTS "${FLUTTER_LIBRARY}")
  add_custom_target(flutter_engine
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_LIBRARY}"
      "${PROJECT_BINARY_DIR}/libflutter_linux_gtk.so"
  )
  add_dependencies(flutter_assemble flutter_engine)
endif()

# Target for ICU data file.
if(EXISTS "${FLUTTER_ICU_DATA_FILE}")
  add_custom_target(flutter_icu
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_ICU_DATA_FILE}"
      "${PROJECT_BINARY_DIR}/icudtl.dat"
  )
  add_dependencies(flutter_assemble flutter_icu)
endif()

# Link the Flutter engine to target applications or plugins.
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE
  "${EPHEMERAL_DIR}"
)
target_link_libraries(flutter INTERFACE
  "${FLUTTER_LIBRARY}"
)
add_dependencies(flutter flutter_assemble)
