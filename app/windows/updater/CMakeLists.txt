# VALUNIVO-Updater.exe — bundled next to VALUNIVO.exe; applies a verified update after the app closes.
cmake_minimum_required(VERSION 3.14)
# FLUTTER_VERSION* (from --build-name / --build-number), same values as VALUNIVO.exe
include("${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral/generated_config.cmake")

add_executable(valunivo_updater WIN32 "main.cpp" "updater.rc")
set_target_properties(valunivo_updater PROPERTIES OUTPUT_NAME "VALUNIVO-Updater")
target_compile_features(valunivo_updater PRIVATE cxx_std_17)
target_compile_options(valunivo_updater PRIVATE /W4 /EHsc /utf-8)
target_compile_definitions(valunivo_updater PRIVATE UNICODE _UNICODE NOMINMAX)
target_link_libraries(valunivo_updater PRIVATE bcrypt wintrust crypt32 version shell32)
# runs as the signed-in user (no UAC prompt) — its name contains "Update", so Windows would otherwise guess "installer"
target_link_options(valunivo_updater PRIVATE "/MANIFESTUAC:level='asInvoker' uiAccess='false'")
target_compile_definitions(valunivo_updater PRIVATE
  "VALUNIVO_VERSION_STRING=\"${FLUTTER_VERSION}\""
  "VALUNIVO_VERSION_NUMBER=${FLUTTER_VERSION_MAJOR},${FLUTTER_VERSION_MINOR},${FLUTTER_VERSION_PATCH},${FLUTTER_VERSION_BUILD}")

install(TARGETS valunivo_updater RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
