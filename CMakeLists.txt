cmake_minimum_required(VERSION 3.13)

# mandelCVB - CVBasic project

# Load project-local configuration (kept small and user-editable)
set(PROJECT_CONFIG_FILE "${CMAKE_SOURCE_DIR}/project-config.cmake")
if(EXISTS "${PROJECT_CONFIG_FILE}")
    include("${PROJECT_CONFIG_FILE}")
else()
    message(STATUS "No project-config.cmake found; using defaults")
    set(PROJECT_NAME mandelcvb)
    set(VERSION "v0-0-1")
    set(MAIN_SOURCE "mandelcvb.bas")
    set(CART_TITLE "MANDELCVB")
    set(ENABLED_TARGETS coleco msx_asc16 msx_konami nabu sg1000 creativision ti99 nabu_mame)
endif()

project(${PROJECT_NAME})

# Include CVBasic build helpers
include(${CMAKE_SOURCE_DIR}/visrealm_cvbasic.cmake)

set(PYTHON python3)

# Version information (used in ROM filenames)
string(REPLACE "-" "." FRIENDLYVER "${VERSION}")

# Helper: check if a target is enabled in ENABLED_TARGETS
function(is_target_enabled NAME OUT_VAR)
    list(FIND ENABLED_TARGETS "${NAME}" _idx)
    if(_idx GREATER -1)
        set(${OUT_VAR} ON PARENT_SCOPE)
    else()
        set(${OUT_VAR} OFF PARENT_SCOPE)
    endif()
endfunction()

is_target_enabled("ti99" TARGET_TI99)
is_target_enabled("coleco" TARGET_COLECO)
is_target_enabled("msx_asc16" TARGET_MSX_ASC16)
is_target_enabled("msx_konami" TARGET_MSX_KONAMI)
is_target_enabled("nabu" TARGET_NABU)
is_target_enabled("sg1000" TARGET_SG1000)
is_target_enabled("creativision" TARGET_CREATIVISION)
is_target_enabled("nabu_mame" TARGET_NABU_MAME)

# Check for GPU assembly files to determine if we need TI-99 tools
file(GLOB_RECURSE GPU_ASM_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/gpu/*.a99")

# Only build/download TI-99 toolchain if that target is requested or GPU files exist
set(_BUILD_TI99_DEFAULT ${TARGET_TI99})
if(GPU_ASM_FILES)
    set(_BUILD_TI99_DEFAULT ON)
endif()
set(BUILD_TI99_TOOLS ${_BUILD_TI99_DEFAULT} CACHE BOOL "Build or locate TI-99 toolchain (XDT99)")

# Setup CVBasic toolchain (auto-build or find existing tools)
setup_cvbasic_tools()

# Set up directories
set(SOURCE_DIR "${CMAKE_SOURCE_DIR}/src")
set(ASM_DIR "${CMAKE_BINARY_DIR}/asm")
set(ROMS_DIR "${CMAKE_BINARY_DIR}/roms")
file(MAKE_DIRECTORY "${ASM_DIR}")
file(MAKE_DIRECTORY "${ROMS_DIR}")

# Collect all CVBasic source files for dependency tracking
# CONFIGURE_DEPENDS makes CMake re-run if new files are added.
file(GLOB CVBASIC_SOURCE_FILES CONFIGURE_DEPENDS
    "${SOURCE_DIR}/*.bas"
    "${SOURCE_DIR}/lib/*.asm"
)

# Collect GPU assembly sources and pletter sources for dependency tracking
file(GLOB_RECURSE GPU_SOURCE_FILES CONFIGURE_DEPENDS "${SOURCE_DIR}/gpu/*.a99")
file(GLOB PLETTER_SOURCE_FILES CONFIGURE_DEPENDS "${SOURCE_DIR}/pletter/*.bas")

# GPU assembly: .a99 -> .bin -> .bin.bas
# Not Pletter-compressed: both blobs are small, and the host has to write them
# to VRAM before the framebuffer exists, so plain DEFINE VRAM is simplest.
cvbasic_process_assets(
    NAME gpu_assets
    SOURCES "${SOURCE_DIR}/gpu/*.a99"
    PIPELINE xas99 bin2cvb
    OUTPUT_DIR "${SOURCE_DIR}/gen/gpu"
)

# Simple pletter compression: .bas -> .pletter.bas
cvbasic_process_assets(
    NAME pletter_compression
    SOURCES "${SOURCE_DIR}/pletter/*.bas"
    PIPELINE pletter
    OUTPUT_DIR "${SOURCE_DIR}/gen/pletter"
)

# Collect outputs from asset processing (cvbasic_process_assets sets CVBASIC_${NAME}_OUTPUTS)
set(PLETTER_OUTPUTS ${CVBASIC_pletter_compression_OUTPUTS})
set(GPU_OUTPUTS ${CVBASIC_gpu_assets_OUTPUTS})

# Base name for ROMs (derived from main source file)
get_filename_component(BASE_NAME "${MAIN_SOURCE}" NAME_WE)

# Setup CVBasic project configuration
cvbasic_setup_project(
    SOURCE_FILE "${MAIN_SOURCE}"
    SOURCE_DIR "${SOURCE_DIR}"
    ASM_DIR "${ASM_DIR}"
    ROMS_DIR "${ROMS_DIR}"
    CART_TITLE "${CART_TITLE}"
    VERSION "${VERSION}"
    PLETTER_TARGET "${CVBASIC_pletter_compression_TARGET}"
    GPU_TARGET "${CVBASIC_gpu_assets_TARGET}"
    DEPENDENCIES ${CVBASIC_SOURCE_FILES} ${GPU_SOURCE_FILES} ${PLETTER_SOURCE_FILES} ${PLETTER_OUTPUTS} ${GPU_OUTPUTS}
    TOOL_DEPS ${TOOL_DEPENDENCIES}
)

# Helper to keep track of added platform targets
set(ALL_PLATFORM_TARGETS "")
function(register_platform_target NAME)
    list(APPEND ALL_PLATFORM_TARGETS ${NAME})
    set(ALL_PLATFORM_TARGETS "${ALL_PLATFORM_TARGETS}" PARENT_SCOPE)
endfunction()

# Define platform targets conditionally
if(TARGET_TI99)
    cvbasic_add_target(ti99 ti994a --ti994a)
    register_platform_target(ti99)
endif()

if(TARGET_COLECO)
    cvbasic_add_target(coleco cv "")
    register_platform_target(coleco)
endif()

if(TARGET_MSX_ASC16)
    cvbasic_add_target(msx_asc16 msx --msx)
    register_platform_target(msx_asc16)
endif()

if(TARGET_MSX_KONAMI)
    cvbasic_add_target(msx_konami msx "--msx;-konami")
    register_platform_target(msx_konami)
endif()

if(TARGET_NABU)
    cvbasic_add_target(nabu nabu --nabu)
    register_platform_target(nabu)
endif()

if(TARGET_SG1000)
    cvbasic_add_target(sg1000 sc3000 --sg1000)
    register_platform_target(sg1000)
endif()

if(TARGET_CREATIVISION)
    cvbasic_add_target(creativision crv "--creativision;-rom16")
    register_platform_target(creativision)
endif()

# NABU MAME target (outputs intermediate to asm dir)
if(TARGET_NABU_MAME)
    set(NABU_MAME_ROM "000001.nabu")
    cvbasic_add_target(nabu_mame nabu --nabu ROM "${NABU_MAME_ROM}" OUTPUT_DIR "${ASM_DIR}")
    register_platform_target(nabu_mame)

    # NABU MAME packaging (package from asm dir to roms dir)
    cvbasic_package_nabu_mame("${NABU_MAME_ROM}" "${BASE_NAME}_${VERSION}_nabu_mame.npz" "${ASM_DIR}" "${ROMS_DIR}")
    add_custom_target(nabu_mame_package DEPENDS "${ROMS_DIR}/${BASE_NAME}_${VERSION}_nabu_mame.npz")
    register_platform_target(nabu_mame_package)
endif()

# Master target to build all platforms
if(ALL_PLATFORM_TARGETS)
    add_custom_target(all_platforms DEPENDS ${ALL_PLATFORM_TARGETS})
endif()

# Print build information
message(STATUS "mandelCVB Configuration")
message(STATUS "Version: ${FRIENDLYVER}")
message(STATUS "Main source: ${MAIN_SOURCE}")
message(STATUS "CVBasic: ${CVBASIC_EXE}")
message(STATUS "GASM80: ${GASM80_EXE}")
message(STATUS "Pletter: ${PLETTER_EXE}")
message(STATUS "linkticart.py: ${LINKTICART_SCRIPT}")
if(XAS99_SCRIPT)
    message(STATUS "XAS99: ${XAS99_SCRIPT}")
else()
    message(STATUS "XAS99: NOT FOUND (TI-99 builds will be limited)")
endif()
