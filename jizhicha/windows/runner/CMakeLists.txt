cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# 让 MSBuild 自动生成带 UAC 的 manifest（requireAdministrator），
# 而不是在 runner.exe.manifest 里写 trustInfo（会和 Flutter 自动生成的 manifest 合并时 mt.exe 报错 LNK1327）。
# 启动 jizhicha.exe 时自动 UAC 提权，整个进程树都是管理员，
# 这样内置 HUSE VPN 加载 Wintun / 改路由表才不会报 ERROR_ELEVATION_REQUIRED。
set_target_properties(${BINARY_NAME} PROPERTIES
  VS_GLOBAL_UACExecutionLevel "requireAdministrator"
)

# Flutter uses the Ninja generator on Windows, so the Visual Studio property
# above is not enough there. Embed the UAC level through the MSVC linker too.
if(MSVC)
  target_link_options(${BINARY_NAME} PRIVATE "/MANIFESTUAC:level='requireAdministrator'")
endif()

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
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
add_dependencies(${BINARY_NAME} huse_vpn_ffi_build)

# 调试期（flutter run）不会执行 install，这里用 POST_BUILD 把内置 HUSE VPN 与 wintun.dll
# 同步拷贝到 build 输出目录（与 exe 同目录），方便直接调试 VPN 一键连接功能。
# 正式打包的拷贝由顶层 CMakeLists 的 install 规则负责。
if(HUSE_VPN_FFI_DLL)
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${HUSE_VPN_FFI_DLL}" "$<TARGET_FILE_DIR:${BINARY_NAME}>/huse_vpn_ffi.dll"
    COMMENT "Copying embedded HUSE VPN FFI engine")
endif()

if(EXISTS "${HUSE_WINTUN_DLL}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${HUSE_WINTUN_DLL}" "$<TARGET_FILE_DIR:${BINARY_NAME}>/wintun.dll"
    COMMENT "Copying bundled wintun.dll next to the executable")
endif()
