cmake_minimum_required(VERSION 3.20)
project(delve_native LANGUAGES CXX)

# godot-cpp is cloned into native/godot-cpp (not committed). Bindings are
# generated against native/godot-api — the extension API + interface dumped
# from the project's custom Godot 4.7.2 + Voxel Tools build, so the voxel
# module's classes (VoxelGeneratorScript, VoxelBuffer, ...) get bindings.
#
#   cmake -S native -B native/build -G "Visual Studio 17 2022" -A x64
#   cmake --build native/build --config Release

set(GODOTCPP_GDEXTENSION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-api"
	CACHE PATH "Dumped GDExtension API dir for this project's engine")
set(GODOTCPP_SYSTEM_HEADERS ON)

add_subdirectory(godot-cpp)

add_library(delve_native SHARED
	src/register_types.cpp
	src/delve_generator.cpp
	src/delve_sim.cpp
)

target_compile_features(delve_native PRIVATE cxx_std_17)
target_include_directories(delve_native PRIVATE src)
target_link_libraries(delve_native PRIVATE godot-cpp)

# The .gdextension file maps configuration keys to DLL names.
set_target_properties(delve_native PROPERTIES
	OUTPUT_NAME "delve_native.windows.editor.x86_64"
	RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	PDB_OUTPUT_DIRECTORY_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/bin"
)
