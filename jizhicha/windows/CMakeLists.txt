# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(jizhicha LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "jizhicha")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Bundle the embedded HUSE VPN native engine next to the Flutter executable.
# This is a DLL loaded by Dart FFI; no separate VPN window or process is used.
set(HUSE_VPN_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../huse-vpn-next" CACHE PATH "HUSE VPN source directory")
set(HUSE_VPN_RELEASE_DLL "${HUSE_VPN_SOURCE_DIR}/target/release/huse_vpn_ffi.dll")
set(HUSE_VPN_FFI_DLL "${HUSE_VPN_RELEASE_DLL}")

# Never package an old native engine by accident. Every Flutter Windows build
# first asks Cargo to produce the exact release DLL copied beside the app.
find_program(CARGO_EXECUTABLE NAMES cargo)
if(NOT CARGO_EXECUTABLE)
  message(FATAL_ERROR "Rust cargo was not found; it is required to build the embedded VPN engine")
endif()
find_program(POWERSHELL_EXECUTABLE NAMES pwsh powershell)
if(NOT POWERSHELL_EXECUTABLE)
  message(FATAL_ERROR "PowerShell was not found; it is required to build the embedded VPN engine")
endif()
add_custom_target(huse_vpn_ffi_build
  COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive
    -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/build_rust.ps1"
    -CargoExecutable "${CARGO_EXECUTABLE}"
    -ManifestPath "${HUSE_VPN_SOURCE_DIR}/Cargo.toml"
    -WorkspacePath "${HUSE_VPN_SOURCE_DIR}"
  WORKING_DIRECTORY "${HUSE_VPN_SOURCE_DIR}"
  BYPRODUCTS "${HUSE_VPN_RELEASE_DLL}"
  COMMENT "Building embedded HUSE VPN FFI engine with Cargo"
  VERBATIM
)

set(HUSE_WINTUN_DLL "${HUSE_VPN_SOURCE_DIR}/target/release/wintun.dll")
if(NOT EXISTS "${HUSE_WINTUN_DLL}")
  set(HUSE_WINTUN_DLL "${HUSE_VPN_SOURCE_DIR}/target/debug/wintun.dll")
endif()
# Keep the signed runtime DLL in the source tree as a final fallback.  A clean
# checkout has no Cargo target directory yet, so relying only on target/...
# silently produces a Windows package that starts without Wintun and fails at
# the first VPN connection.
if(NOT EXISTS "${HUSE_WINTUN_DLL}")
  set(HUSE_WINTUN_DLL "${CMAKE_CURRENT_SOURCE_DIR}/wintun/wintun.dll")
endif()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 打包内置 HUSE VPN 客户端（用于一键建立校园网 VPN 隧道），放到可执行文件同目录。
# install 规则用于正式打包；调试期（flutter run）的同步拷贝放在 runner/CMakeLists.txt
# 的 POST_BUILD 里，因为 jizhicha 这个 target 是在那里定义的。
if(HUSE_VPN_FFI_DLL)
  install(FILES "${HUSE_VPN_FFI_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "huse_vpn_ffi.dll" COMPONENT Runtime)
endif()

# 打包 wintun.dll（HUSE VPN 依赖的 Windows TUN 驱动包装，必须与客户端同目录）。
if(EXISTS "${HUSE_WINTUN_DLL}")
  install(FILES "${HUSE_WINTUN_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "wintun.dll" COMPONENT Runtime)
endif()

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
