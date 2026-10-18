cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "clipboard_image_channel.cpp"
  "flutter_window.cpp"
  "global_hotkeys_channel.cpp"
  "main.cpp"
  "now_playing_channel.cpp"
  "single_instance.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# The SMTC reader needs C++/WinRT, which throws. apply_standard_settings turns
# exceptions off and warnings into errors for the runner, so it is its own
# library with neither.
file(GLOB CPPWINRT_DIRS
  "$ENV{ProgramFiles\(x86\)}/Windows Kits/10/Include/*/cppwinrt")
list(SORT CPPWINRT_DIRS)
add_library(now_playing_smtc STATIC "now_playing_smtc.cpp")
target_compile_features(now_playing_smtc PUBLIC cxx_std_17)
target_compile_definitions(now_playing_smtc PRIVATE "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_include_directories(now_playing_smtc PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
if(CPPWINRT_DIRS)
  list(GET CPPWINRT_DIRS -1 CPPWINRT_LATEST)
  target_include_directories(now_playing_smtc PRIVATE "${CPPWINRT_LATEST}")
endif()
target_link_libraries(now_playing_smtc PUBLIC "windowsapp")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowscodecs.lib")
target_link_libraries(${BINARY_NAME} PRIVATE now_playing_smtc)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
