cmake_minimum_required(VERSION 3.12)

# CVBasic build helpers (derived from RetroPIPE)

include(ExternalProject)
set(PYTHON python3)

# Define a job pool with 1 slot to serialize CVBasic compilation
# This prevents multiple CVBasic instances from conflicting on cvbasic_temporary.asm
set_property(GLOBAL PROPERTY JOB_POOLS cvbasic_pool=1)

# Find CVBasic tools with fallback paths
function(find_cvbasic_tools)
    find_program(CVBASIC_EXECUTABLE cvbasic
        PATHS
            ${CMAKE_SOURCE_DIR}/tools/cvbasic
            ${CMAKE_SOURCE_DIR}/../CVBasic/build
            ${CMAKE_SOURCE_DIR}/../CVBasic/build/Release
            ENV PATH
        DOC "CVBasic compiler executable"
    )

    find_program(GASM80_EXECUTABLE gasm80
        PATHS
            ${CMAKE_SOURCE_DIR}/tools/cvbasic
            ${CMAKE_SOURCE_DIR}/../gasm80/build/Release
            ENV PATH
        DOC "GASM80 assembler executable"
    )

    if(WIN32)
        find_program(XAS99_SCRIPT xas99.py
            PATHS c:/tools/xdt99
            DOC "XDT99 XAS99 assembler script"
        )
    endif()

    # Set parent scope variables
    set(CVBASIC_FOUND ${CVBASIC_EXECUTABLE} PARENT_SCOPE)
    set(GASM80_FOUND ${GASM80_EXECUTABLE} PARENT_SCOPE)
    set(XAS99_FOUND ${XAS99_SCRIPT} PARENT_SCOPE)

    if(CVBASIC_EXECUTABLE)
        message(STATUS "Found CVBasic: ${CVBASIC_EXECUTABLE}")
    else()
        message(WARNING "CVBasic not found - builds will fail")
    endif()

    if(GASM80_EXECUTABLE)
        message(STATUS "Found GASM80: ${GASM80_EXECUTABLE}")
    else()
        message(WARNING "GASM80 not found - some platform builds will fail")
    endif()

    if(XAS99_SCRIPT)
        message(STATUS "Found XAS99: ${XAS99_SCRIPT}")
    else()
        message(STATUS "XAS99 not found - TI-99 builds will be limited")
    endif()
endfunction()

# Setup CVBasic toolchain - either by finding existing tools or building from source
#
# Version control:
# Use cmake cache variables to specify tool versions:
#   -DCVBASIC_GIT_TAG=v1.2.3    (default: master)
#   -DGASM80_GIT_TAG=v0.9.1     (default: master)
#   -DXDT99_GIT_TAG=3.5.0       (default: master)
#
# Examples:
#   cmake .. -DCVBASIC_GIT_TAG=v1.2.3
#   cmake .. -DGASM80_GIT_TAG=v0.9.1 -DXDT99_GIT_TAG=3.5.0
#
function(setup_cvbasic_tools)
    option(BUILD_TOOLS_FROM_SOURCE "Build CVBasic, gasm80 and XDT99 from source" ON)
    option(BUILD_TI99_TOOLS "Build or locate TI-99 tooling (XDT99)" ON)

    # Allow overriding just the CVBasic executable when testing local builds
    set(CVBASIC_CUSTOM_EXE "" CACHE FILEPATH "Path to prebuilt CVBasic executable to use (skips building CVBasic)")

    # Tool version/tag configuration
    set(CVBASIC_GIT_TAG "master" CACHE STRING "CVBasic git tag/branch/commit")
    set(GASM80_GIT_TAG "master" CACHE STRING "GASM80 git tag/branch/commit")
    set(XDT99_GIT_TAG "master" CACHE STRING "XDT99 git tag/branch/commit")
    set(PLETTER_GIT_TAG "master" CACHE STRING "Pletter git tag/branch/commit")

    if(BUILD_TOOLS_FROM_SOURCE)
        # Use system default compilers for host builds
        if(WIN32)
            # On Windows, let CMake find the default system compiler
            set(HOST_CMAKE_ARGS "")
        else()
            # On Unix, explicitly specify common compiler paths
            set(HOST_CMAKE_ARGS
                "-DCMAKE_C_COMPILER=gcc"
                "-DCMAKE_CXX_COMPILER=g++"
            )
        endif()

        set(TOOL_DEP_LIST "")

        if(CVBASIC_CUSTOM_EXE)
            # Use caller-provided CVBasic instead of building
            set(CVBASIC_EXE "${CVBASIC_CUSTOM_EXE}" PARENT_SCOPE)
            message(STATUS "Using custom CVBasic executable: ${CVBASIC_CUSTOM_EXE}")
        else()
            # Build CVBasic from visrealm fork using separate process to avoid cross-compilation issues
            ExternalProject_Add(CVBasic_external
                GIT_REPOSITORY https://github.com/visrealm/CVBasic.git
                GIT_TAG ${CVBASIC_GIT_TAG}
                CMAKE_ARGS
                    -DCMAKE_BUILD_TYPE=Release
                    -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/external/CVBasic
                BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config Release
                INSTALL_COMMAND
                    ${CMAKE_COMMAND} --install <BINARY_DIR> --config Release &&
                    ${CMAKE_COMMAND} -E copy_if_different <SOURCE_DIR>/linkticart.py ${CMAKE_BINARY_DIR}/external/CVBasic/
                UPDATE_DISCONNECTED ON
            )
            list(APPEND TOOL_DEP_LIST CVBasic_external)
            set(CVBASIC_EXE "${CMAKE_BINARY_DIR}/external/CVBasic/bin/cvbasic" PARENT_SCOPE)
        endif()

        # Build gasm80 from visrealm fork using separate process to avoid cross-compilation issues
        ExternalProject_Add(gasm80_external
            GIT_REPOSITORY https://github.com/visrealm/gasm80.git
            GIT_TAG ${GASM80_GIT_TAG}
            CMAKE_ARGS
                -DCMAKE_BUILD_TYPE=Release
                -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/external/gasm80
            BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config Release
            INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config Release
            UPDATE_DISCONNECTED ON
        )

        list(APPEND TOOL_DEP_LIST gasm80_external Pletter_external)

        # Build XDT99 tools (Python-based)
        if(BUILD_TI99_TOOLS)
            ExternalProject_Add(XDT99_external
                GIT_REPOSITORY https://github.com/endlos99/xdt99.git
                GIT_TAG ${XDT99_GIT_TAG}
                CONFIGURE_COMMAND ""
                BUILD_COMMAND ""
                INSTALL_COMMAND
                    ${CMAKE_COMMAND} -E copy_directory <SOURCE_DIR> ${CMAKE_BINARY_DIR}/external/xdt99
                UPDATE_DISCONNECTED ON
            )
            list(APPEND TOOL_DEP_LIST XDT99_external)
        endif()

        # Build Pletter compression tool (simple C file - create CMakeLists.txt on-the-fly)
        file(WRITE ${CMAKE_BINARY_DIR}/pletter_CMakeLists.txt
"cmake_minimum_required(VERSION 3.5)
project(pletter C)
set(CMAKE_C_STANDARD 11)
add_executable(pletter pletter.c)
# Define MAX_PATH for all platforms (MSVC needs 260, Unix typically uses 4096 or PATH_MAX)
if(MSVC)
    add_definitions(-D_CRT_SECURE_NO_WARNINGS)
    target_compile_definitions(pletter PRIVATE MAX_PATH=260)
else()
    # Linux/macOS/Unix - use PATH_MAX equivalent
    target_compile_definitions(pletter PRIVATE MAX_PATH=4096)
endif()
install(TARGETS pletter RUNTIME DESTINATION bin)
")
        ExternalProject_Add(Pletter_external
            GIT_REPOSITORY https://github.com/nanochess/Pletter.git
            GIT_TAG ${PLETTER_GIT_TAG}
            PATCH_COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/pletter_CMakeLists.txt <SOURCE_DIR>/CMakeLists.txt
            CMAKE_ARGS
                -DCMAKE_BUILD_TYPE=Release
                -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/external/pletter
            BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config Release
            INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config Release
            UPDATE_DISCONNECTED ON
        )

        # Set tool paths for external builds
        set(GASM80_EXE "${CMAKE_BINARY_DIR}/external/gasm80/bin/gasm80" PARENT_SCOPE)
        if(BUILD_TI99_TOOLS)
            set(XAS99_SCRIPT "${CMAKE_BINARY_DIR}/external/xdt99/xas99.py" PARENT_SCOPE)
        else()
            set(XAS99_SCRIPT "" PARENT_SCOPE)
        endif()
        if(CVBASIC_CUSTOM_EXE)
            # Try to locate linkticart alongside the custom CVBasic; fallback handled later
            get_filename_component(_CVB_CUSTOM_DIR "${CVBASIC_CUSTOM_EXE}" DIRECTORY)
            get_filename_component(_CVB_CUSTOM_PARENT "${_CVB_CUSTOM_DIR}" DIRECTORY)
            find_file(LINKTICART_SCRIPT linkticart.py
                PATHS
                    "${_CVB_CUSTOM_DIR}"
                    "${_CVB_CUSTOM_PARENT}"
                    "${CMAKE_SOURCE_DIR}/tools/cvbasic"
            )
            if(LINKTICART_SCRIPT)
                set(LINKTICART_SCRIPT "${LINKTICART_SCRIPT}" PARENT_SCOPE)
            else()
                set(LINKTICART_SCRIPT "" PARENT_SCOPE)
            endif()
        else()
            set(LINKTICART_SCRIPT "${CMAKE_BINARY_DIR}/external/CVBasic/linkticart.py" PARENT_SCOPE)
        endif()
        set(PLETTER_EXE "${CMAKE_BINARY_DIR}/external/pletter/bin/pletter" PARENT_SCOPE)

        # Add dependencies to all CVBasic targets
        set(TOOL_DEPENDENCIES ${TOOL_DEP_LIST} PARENT_SCOPE)

        if(CVBASIC_CUSTOM_EXE)
            message(STATUS "CVBasic build skipped (custom executable provided)")
        else()
            message(STATUS "CVBasic tools will be built from source")
            message(STATUS "CVBasic version/tag: ${CVBASIC_GIT_TAG}")
        endif()
        message(STATUS "GASM80 version/tag: ${GASM80_GIT_TAG}")
        if(BUILD_TI99_TOOLS)
            message(STATUS "XDT99 version/tag: ${XDT99_GIT_TAG}")
        else()
            message(STATUS "XDT99: skipped (TI-99 target disabled)")
        endif()
        message(STATUS "Pletter version/tag: ${PLETTER_GIT_TAG}")
    else()
        # Find required tools (original behavior), allowing override
        if(CVBASIC_CUSTOM_EXE)
            set(CVBASIC_EXE "${CVBASIC_CUSTOM_EXE}")
            message(STATUS "Using custom CVBasic executable: ${CVBASIC_CUSTOM_EXE}")
        else()
            find_program(CVBASIC_EXE cvbasic PATHS ${CMAKE_SOURCE_DIR}/tools/cvbasic ${CMAKE_SOURCE_DIR}/../CVBasic/build/Release REQUIRED)
        endif()
        find_program(GASM80_EXE gasm80 PATHS ${CMAKE_SOURCE_DIR}/tools/cvbasic ${CMAKE_SOURCE_DIR}/../gasm80/build/Release REQUIRED)

        # Find linkticart.py in local CVBasic installation or fallback to bundled version
        if(CVBASIC_CUSTOM_EXE)
            get_filename_component(_CVB_CUSTOM_DIR "${CVBASIC_CUSTOM_EXE}" DIRECTORY)
            get_filename_component(_CVB_CUSTOM_PARENT "${_CVB_CUSTOM_DIR}" DIRECTORY)
            find_file(LINKTICART_SCRIPT linkticart.py
                PATHS
                    "${_CVB_CUSTOM_DIR}"
                    "${_CVB_CUSTOM_PARENT}"
                    ${CMAKE_SOURCE_DIR}/../CVBasic
                    ${CMAKE_SOURCE_DIR}/tools/cvbasic
                DOC "CVBasic linkticart.py script"
            )
        else()
            find_file(LINKTICART_SCRIPT linkticart.py
                PATHS
                    ${CMAKE_SOURCE_DIR}/../CVBasic
                    ${CMAKE_SOURCE_DIR}/tools/cvbasic
                DOC "CVBasic linkticart.py script"
            )
        endif()
        if(NOT LINKTICART_SCRIPT)
            set(LINKTICART_SCRIPT "${CMAKE_SOURCE_DIR}/tools/cvbasic/linkticart.py")
        endif()

        # Platform-specific tool paths (only if TI-99 is requested)
        if(BUILD_TI99_TOOLS)
            if(WIN32)
                find_program(XAS99_SCRIPT xas99.py PATHS c:/tools/xdt99)
                if(NOT XAS99_SCRIPT)
                    message(WARNING "XAS99 not found, TI-99 builds will be skipped")
                endif()
            else()
                find_program(XAS99_SCRIPT xas99.py PATHS /usr/local/bin /opt/xdt99)
                if(NOT XAS99_SCRIPT)
                    message(WARNING "XAS99 not found, TI-99 builds will be skipped")
                endif()
            endif()
        else()
            set(XAS99_SCRIPT "")
        endif()

        set(TOOL_DEPENDENCIES "" PARENT_SCOPE)

        message(STATUS "Using existing CVBasic tools")
        message(STATUS "CVBasic: ${CVBASIC_EXE}")
        message(STATUS "GASM80: ${GASM80_EXE}")
        message(STATUS "linkticart.py: ${LINKTICART_SCRIPT}")
        if(BUILD_TI99_TOOLS)
            if(XAS99_SCRIPT)
                message(STATUS "XAS99: ${XAS99_SCRIPT}")
            else()
                message(STATUS "XAS99: NOT FOUND (TI-99 builds will be limited)")
            endif()
        else()
            message(STATUS "XAS99: skipped (TI-99 target disabled)")
        endif()
    endif()
endfunction()

# Assemble TI-99 assembly file with XAS99 and link to cartridge format
# Creates a custom command that assembles the .a99 file and links it to a .bin cartridge
function(cvbasic_assemble_ti99 ASM_FILE ROM_OUTPUT CART_TITLE ASM_DIR ROMS_DIR TOOL_DEPS)
    if(XAS99_SCRIPT)
        # XAS99 generates .bin file based on assembly filename
        get_filename_component(ASM_NAME "${ASM_FILE}" NAME_WE)
        
        # Check if banking is used by looking for _b0.bin file after assembly
        # If banking exists, use _b0.bin as input to linkticart, otherwise use .bin
        add_custom_command(
            OUTPUT "${ROMS_DIR}/${ROM_OUTPUT}"
            COMMAND ${PYTHON} "${XAS99_SCRIPT}" -b -R "${ASM_DIR}/${ASM_FILE}"
            COMMAND ${CMAKE_COMMAND} -E echo "Linking TI-99 cartridge..."
            COMMAND ${CMAKE_COMMAND}
                -DASM_DIR=${ASM_DIR}
                -DASM_NAME=${ASM_NAME}
                -DLINKTICART_SCRIPT=${LINKTICART_SCRIPT}
                -DPYTHON=${PYTHON}
                -DROMS_DIR=${ROMS_DIR}
                -DROM_OUTPUT=${ROM_OUTPUT}
                -DCART_TITLE=${CART_TITLE}
                -P "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/ti99_link_helper.cmake"
            DEPENDS "${ASM_DIR}/${ASM_FILE}" ${TOOL_DEPS}
            WORKING_DIRECTORY "${ASM_DIR}"
            COMMENT "Assembling TI-99 cartridge: ${ROM_OUTPUT}"
            VERBATIM
        )
    else()
        # Create a dummy target when XAS99 is not available
        add_custom_command(
            OUTPUT "${ROMS_DIR}/${ROM_OUTPUT}"
            COMMAND ${CMAKE_COMMAND} -E echo "XAS99 not available, skipping TI-99 build"
            COMMAND ${CMAKE_COMMAND} -E touch "${ROMS_DIR}/${ROM_OUTPUT}"
            DEPENDS "${ASM_DIR}/${ASM_FILE}"
            COMMENT "Skipping TI-99 build (XAS99 not found)"
        )
    endif()
endfunction()

# Assemble with GASM80 (for most platforms)
function(cvbasic_assemble_gasm80 ASM_FILE ROM_OUTPUT ASM_DIR ROMS_DIR TOOL_DEPS)
    add_custom_command(
        OUTPUT "${ROMS_DIR}/${ROM_OUTPUT}"
        COMMAND ${GASM80_EXE} "${ASM_DIR}/${ASM_FILE}" -o "${ROMS_DIR}/${ROM_OUTPUT}"
        DEPENDS "${ASM_DIR}/${ASM_FILE}" ${TOOL_DEPS}
        WORKING_DIRECTORY "${ASM_DIR}"
        COMMENT "Assembling with GASM80: ${ROM_OUTPUT}"
        VERBATIM
    )
endfunction()

# Package NABU MAME file into .npz format
# Takes a .nabu file and packages it into a .npz (zip) file
function(cvbasic_package_nabu_mame NABU_FILE OUTPUT_NPZ SOURCE_DIR OUTPUT_DIR)
    add_custom_command(
        OUTPUT "${OUTPUT_DIR}/${OUTPUT_NPZ}"
        COMMAND ${CMAKE_COMMAND} -E tar "cf" "${OUTPUT_DIR}/${OUTPUT_NPZ}.tmp.zip" --format=zip "${NABU_FILE}"
        COMMAND ${CMAKE_COMMAND} -E copy "${OUTPUT_DIR}/${OUTPUT_NPZ}.tmp.zip" "${OUTPUT_DIR}/${OUTPUT_NPZ}"
        COMMAND ${CMAKE_COMMAND} -E remove "${OUTPUT_DIR}/${OUTPUT_NPZ}.tmp.zip"
        DEPENDS "${SOURCE_DIR}/${NABU_FILE}"
        WORKING_DIRECTORY "${SOURCE_DIR}"
        COMMENT "Packaging NABU MAME: ${OUTPUT_NPZ}"
        VERBATIM
    )
endfunction()

# Scan an assembly file for COPY directives and return all dependencies
# This recursively scans included files to build a complete dependency list
function(scan_asm_dependencies ASM_FILE OUT_DEPS)
    set(ALL_DEPS "${ASM_FILE}")
    set(TO_SCAN "${ASM_FILE}")
    set(SCANNED "")

    while(TO_SCAN)
        list(POP_FRONT TO_SCAN CURRENT_FILE)
        list(FIND SCANNED "${CURRENT_FILE}" ALREADY_SCANNED)
        if(ALREADY_SCANNED GREATER -1)
            continue()
        endif()
        list(APPEND SCANNED "${CURRENT_FILE}")

        if(EXISTS "${CURRENT_FILE}")
            file(STRINGS "${CURRENT_FILE}" FILE_LINES)
            get_filename_component(FILE_DIR "${CURRENT_FILE}" DIRECTORY)

            foreach(LINE ${FILE_LINES})
                # Match COPY "filename" or COPY 'filename' (case-insensitive)
                if(LINE MATCHES "^[ \t]*[Cc][Oo][Pp][Yy][ \t]+[\"']([^\"']+)[\"']")
                    set(COPY_FILE "${CMAKE_MATCH_1}")
                    # Resolve relative to the file's directory
                    if(NOT IS_ABSOLUTE "${COPY_FILE}")
                        set(COPY_FILE "${FILE_DIR}/${COPY_FILE}")
                    endif()
                    get_filename_component(COPY_FILE "${COPY_FILE}" ABSOLUTE)
                    if(EXISTS "${COPY_FILE}")
                        list(FIND ALL_DEPS "${COPY_FILE}" ALREADY_ADDED)
                        if(ALREADY_ADDED EQUAL -1)
                            list(APPEND ALL_DEPS "${COPY_FILE}")
                            list(APPEND TO_SCAN "${COPY_FILE}")
                        endif()
                    endif()
                endif()
            endforeach()
        endif()
    endwhile()

    set(${OUT_DEPS} "${ALL_DEPS}" PARENT_SCOPE)
endfunction()

# Universal asset processing function
# Supports multiple processing pipelines: xas99 -> bin2cvb -> pletter
#
# Parameters:
#   NAME       - Target name for this asset group
#   SOURCES    - Source file pattern (e.g., "${SOURCE_DIR}/gpu/*.a99")
#   PIPELINE   - Processing steps: xas99, bin2cvb, pletter (can be combined)
#   OUTPUT_DIR - Where to place final outputs
#   BUILD_DIR  - Intermediate build directory (optional, defaults to ${CMAKE_BINARY_DIR}/${NAME})
#   TOOL_DEPS  - Tool dependencies (optional, defaults to ${TOOL_DEPENDENCIES})
#
# Outputs (parent scope):
#   CVBASIC_${NAME}_OUTPUTS - list of generated files
#   CVBASIC_${NAME}_TARGET  - custom target name
#
# Examples:
#   # GPU assembly: .a99 -> .bin -> .bin.bas -> .bin.pletter.bas
#   cvbasic_process_assets(
#       NAME gpu_assets
#       SOURCES "${SOURCE_DIR}/gpu/*.a99"
#       PIPELINE xas99 bin2cvb pletter
#       OUTPUT_DIR "${SOURCE_DIR}/gen/gpu"
#   )
#
#   # Simple pletter compression: .bas -> .pletter.bas
#   cvbasic_process_assets(
#       NAME pletter_compression
#       SOURCES "${SOURCE_DIR}/pletter/*.bas"
#       PIPELINE pletter
#       OUTPUT_DIR "${SOURCE_DIR}/gen/pletter"
#   )
#
function(cvbasic_process_assets)
    cmake_parse_arguments(PROC "" "NAME;OUTPUT_DIR;BUILD_DIR" "SOURCES;PIPELINE;TOOL_DEPS" ${ARGN})

    if(NOT PROC_NAME)
        message(FATAL_ERROR "cvbasic_process_assets: NAME is required")
    endif()

    if(NOT PROC_SOURCES)
        message(FATAL_ERROR "cvbasic_process_assets: SOURCES is required")
    endif()

    if(NOT PROC_PIPELINE)
        message(FATAL_ERROR "cvbasic_process_assets: PIPELINE is required")
    endif()

    if(NOT PROC_OUTPUT_DIR)
        message(FATAL_ERROR "cvbasic_process_assets: OUTPUT_DIR is required")
    endif()

    if(NOT PROC_BUILD_DIR)
        set(PROC_BUILD_DIR "${CMAKE_BINARY_DIR}/${PROC_NAME}")
    endif()

    if(NOT PROC_TOOL_DEPS)
        set(PROC_TOOL_DEPS ${TOOL_DEPENDENCIES})
    endif()

    # Expand glob pattern to get source files
    file(GLOB SOURCE_FILES CONFIGURE_DEPENDS ${PROC_SOURCES})

    if(NOT SOURCE_FILES)
        set(CVBASIC_${PROC_NAME}_OUTPUTS "" PARENT_SCOPE)
        set(CVBASIC_${PROC_NAME}_TARGET "" PARENT_SCOPE)
        return()
    endif()

    # Check if pipeline steps are valid and required tools are available
    list(FIND PROC_PIPELINE "xas99" HAS_XAS99)
    list(FIND PROC_PIPELINE "bin2cvb" HAS_BIN2CVB)
    list(FIND PROC_PIPELINE "pletter" HAS_PLETTER)

    if(HAS_XAS99 GREATER -1 AND NOT XAS99_SCRIPT)
        message(FATAL_ERROR "Pipeline requires xas99 but XAS99_SCRIPT is not configured")
    endif()

    if(HAS_PLETTER GREATER -1 AND NOT PLETTER_EXE)
        message(FATAL_ERROR "Pipeline requires pletter but PLETTER_EXE is not configured")
    endif()

    # Set up pletter exe path if needed
    if(HAS_PLETTER GREATER -1)
        if(WIN32)
            set(PLETTER_EXE_PATH "${PLETTER_EXE}.exe")
        else()
            set(PLETTER_EXE_PATH "${PLETTER_EXE}")
        endif()
    endif()

    file(MAKE_DIRECTORY "${PROC_BUILD_DIR}")
    file(MAKE_DIRECTORY "${PROC_OUTPUT_DIR}")

    set(ALL_OUTPUTS "")

    foreach(SOURCE_FILE ${SOURCE_FILES})
        get_filename_component(BASENAME ${SOURCE_FILE} NAME_WE)
        get_filename_component(EXTENSION ${SOURCE_FILE} EXT)

        set(CURRENT_FILE "${SOURCE_FILE}")
        set(FILE_OUTPUTS "")

        # Step 1: xas99 assembly (.a99 -> .bin)
        if(HAS_XAS99 GREATER -1)
            set(BIN_OUTPUT "${PROC_BUILD_DIR}/${BASENAME}.bin")
            # Scan for COPY dependencies to ensure rebuilds when included files change
            scan_asm_dependencies("${CURRENT_FILE}" ASM_DEPS)
            add_custom_command(
                OUTPUT "${BIN_OUTPUT}"
                COMMAND ${CMAKE_COMMAND} -E make_directory "${PROC_BUILD_DIR}"
                COMMAND ${PYTHON} "${XAS99_SCRIPT}" -18 -b -R -o "${BIN_OUTPUT}" "${CURRENT_FILE}"
                DEPENDS ${ASM_DEPS} ${PROC_TOOL_DEPS}
                WORKING_DIRECTORY "${PROC_BUILD_DIR}"
                COMMENT "Assembling ${BASENAME}${EXTENSION}"
                VERBATIM
            )
            set(CURRENT_FILE "${BIN_OUTPUT}")
            list(APPEND FILE_OUTPUTS "${BIN_OUTPUT}")
        endif()

        # Step 2: bin2cvb conversion (.bin -> .bin.bas)
        if(HAS_BIN2CVB GREATER -1)
            # Determine input file extension
            if(HAS_XAS99 GREATER -1)
                set(BAS_INPUT "${PROC_BUILD_DIR}/${BASENAME}.bin")
            else()
                set(BAS_INPUT "${SOURCE_FILE}")
            endif()

            set(BAS_OUTPUT "${PROC_OUTPUT_DIR}/${BASENAME}.bin.bas")
            add_custom_command(
                OUTPUT "${BAS_OUTPUT}"
                COMMAND ${PYTHON} "${CMAKE_SOURCE_DIR}/tools/bin2cvb.py" --chunksize 2048 "${BAS_INPUT}" -o "${BAS_OUTPUT}"
                DEPENDS "${BAS_INPUT}" "${CMAKE_SOURCE_DIR}/tools/bin2cvb.py"
                WORKING_DIRECTORY "${PROC_BUILD_DIR}"
                COMMENT "Converting ${BASENAME}.bin to CVBasic data"
                VERBATIM
            )
            set(CURRENT_FILE "${BAS_OUTPUT}")
            list(APPEND FILE_OUTPUTS "${BAS_OUTPUT}")
        endif()

        # Step 3: pletter compression (.bas -> .pletter.bas)
        if(HAS_PLETTER GREATER -1)
            # Determine input for pletter
            if(HAS_BIN2CVB GREATER -1)
                set(PLETTER_INPUT "${PROC_OUTPUT_DIR}/${BASENAME}.bin.bas")
                set(PLETTER_OUTPUT "${PROC_OUTPUT_DIR}/${BASENAME}.bin.pletter.bas")
                set(COMMENT_NAME "${BASENAME}.bin.bas")
            else()
                set(PLETTER_INPUT "${SOURCE_FILE}")
                set(PLETTER_OUTPUT "${PROC_OUTPUT_DIR}/${BASENAME}.pletter.bas")
                set(COMMENT_NAME "${BASENAME}${EXTENSION}")
            endif()

            add_custom_command(
                OUTPUT "${PLETTER_OUTPUT}"
                COMMAND ${CMAKE_COMMAND} -E make_directory "${PROC_OUTPUT_DIR}"
                COMMAND ${CMAKE_COMMAND} -E env "PLETTER_EXE=${PLETTER_EXE_PATH}"
                        ${PYTHON} "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" "${PLETTER_INPUT}" -o "${PROC_OUTPUT_DIR}"
                DEPENDS "${PLETTER_INPUT}" "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" ${PROC_TOOL_DEPS}
                WORKING_DIRECTORY "${PROC_OUTPUT_DIR}"
                COMMENT "Compressing ${COMMENT_NAME}"
                VERBATIM
            )
            set(CURRENT_FILE "${PLETTER_OUTPUT}")
            list(APPEND FILE_OUTPUTS "${PLETTER_OUTPUT}")
        endif()

        # If no processing pipeline matched, just copy the outputs we have
        if(NOT FILE_OUTPUTS)
            message(WARNING "No valid pipeline steps for ${SOURCE_FILE}")
        else()
            list(APPEND ALL_OUTPUTS ${FILE_OUTPUTS})
        endif()
    endforeach()

    if(ALL_OUTPUTS)
        add_custom_target(${PROC_NAME} DEPENDS ${ALL_OUTPUTS})
        set(CVBASIC_${PROC_NAME}_OUTPUTS ${ALL_OUTPUTS} PARENT_SCOPE)
        set(CVBASIC_${PROC_NAME}_TARGET ${PROC_NAME} PARENT_SCOPE)
    else()
        set(CVBASIC_${PROC_NAME}_OUTPUTS "" PARENT_SCOPE)
        set(CVBASIC_${PROC_NAME}_TARGET "" PARENT_SCOPE)
    endif()
endfunction()

# Pletter compression for CVBasic sources
# Parameters (all optional):
#   SOURCE_DIR - location of .bas sources to compress (default: ${CMAKE_SOURCE_DIR}/src/pletter)
#   OUTPUT_DIR - directory for compressed .pletter.bas files (default: ${CMAKE_SOURCE_DIR}/src)
#   TARGET     - custom target name (default: pletter_compression)
#   TOOL_DEPS  - list of tool dependencies (e.g., Pletter_external)
# Outputs (parent scope):
#   CVBASIC_PLETTER_OUTPUTS - list of generated .pletter.bas files
#   CVBASIC_PLETTER_TARGET  - custom target name (empty if no sources)
function(cvbasic_setup_pletter_compression)
    cmake_parse_arguments(PLET "" "SOURCE_DIR;OUTPUT_DIR;TARGET" "TOOL_DEPS" ${ARGN})

    if(NOT PLET_SOURCE_DIR)
        set(PLET_SOURCE_DIR "${CMAKE_SOURCE_DIR}/src/pletter")
    endif()
    if(NOT PLET_OUTPUT_DIR)
        set(PLET_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/src")
    endif()
    if(NOT PLET_TARGET)
        set(PLET_TARGET pletter_compression)
    endif()

    # Glob all .bas files but exclude .pletter.bas files (those are outputs, not inputs)
    file(GLOB PLETTER_ALL_FILES CONFIGURE_DEPENDS "${PLET_SOURCE_DIR}/*.bas")
    set(PLETTER_SOURCE_FILES "")
    foreach(FILE ${PLETTER_ALL_FILES})
        if(NOT FILE MATCHES "\\.pletter\\.bas$")
            list(APPEND PLETTER_SOURCE_FILES "${FILE}")
        endif()
    endforeach()

    if(NOT PLETTER_SOURCE_FILES)
        set(CVBASIC_PLETTER_OUTPUTS "" PARENT_SCOPE)
        set(CVBASIC_PLETTER_TARGET "" PARENT_SCOPE)
        return()
    endif()

    if(NOT PLETTER_EXE)
        message(FATAL_ERROR "Pletter source files detected in ${PLET_SOURCE_DIR} but PLETTER_EXE is not configured.")
    endif()

    file(MAKE_DIRECTORY "${PLET_OUTPUT_DIR}")

    # Set PLETTER_EXE path based on platform
    if(WIN32)
        set(PLETTER_EXE_PATH "${PLETTER_EXE}.exe")
    else()
        set(PLETTER_EXE_PATH "${PLETTER_EXE}")
    endif()

    set(PLETTER_OUTPUTS "")

    foreach(PLETTER_FILE ${PLETTER_SOURCE_FILES})
        get_filename_component(BASENAME ${PLETTER_FILE} NAME_WE)
        set(OUTPUT_FILE "${PLET_OUTPUT_DIR}/${BASENAME}.pletter.bas")

        add_custom_command(
            OUTPUT "${OUTPUT_FILE}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${PLET_OUTPUT_DIR}"
            COMMAND ${CMAKE_COMMAND} -E env "PLETTER_EXE=${PLETTER_EXE_PATH}"
                    ${PYTHON} "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" "${PLETTER_FILE}" -o "${PLET_OUTPUT_DIR}"
            DEPENDS "${PLETTER_FILE}" "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" ${PLET_TOOL_DEPS}
            WORKING_DIRECTORY "${PLET_SOURCE_DIR}"
            COMMENT "Compressing ${BASENAME}.bas -> gen/pletter/${BASENAME}.pletter.bas"
            VERBATIM
        )

        list(APPEND PLETTER_OUTPUTS "${OUTPUT_FILE}")
    endforeach()

    add_custom_target(${PLET_TARGET} DEPENDS ${PLETTER_OUTPUTS})

    set(CVBASIC_PLETTER_OUTPUTS ${PLETTER_OUTPUTS} PARENT_SCOPE)
    set(CVBASIC_PLETTER_TARGET ${PLET_TARGET} PARENT_SCOPE)
endfunction()

# Convert GPU assembly (.a99) into CVBasic data (.bin.bas) with optional Pletter compression
# Parameters (all optional):
#   SOURCE_DIR - location of .a99 sources (default: ${CMAKE_SOURCE_DIR}/src/gpu)
#   OUTPUT_DIR - directory for generated .bas data (default: ${CMAKE_SOURCE_DIR}/src)
#   BUILD_DIR  - intermediate build directory (default: ${CMAKE_BINARY_DIR}/gpu)
#   TARGET     - custom target name (default: gpu_assets)
#   PLETTER    - option flag to enable Pletter compression of outputs
#   TOOL_DEPS  - list of tool dependencies (e.g., XDT99_external, Pletter_external)
# Outputs (parent scope):
#   CVBASIC_GPU_OUTPUTS - list of generated files
#   CVBASIC_GPU_TARGET  - custom target name (empty if no sources)
function(cvbasic_setup_gpu_assets)
    cmake_parse_arguments(GPU "PLETTER" "SOURCE_DIR;OUTPUT_DIR;BUILD_DIR;TARGET" "TOOL_DEPS" ${ARGN})

    if(NOT GPU_SOURCE_DIR)
        set(GPU_SOURCE_DIR "${CMAKE_SOURCE_DIR}/src/gpu")
    endif()
    if(NOT GPU_OUTPUT_DIR)
        set(GPU_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/src")
    endif()
    if(NOT GPU_BUILD_DIR)
        set(GPU_BUILD_DIR "${CMAKE_BINARY_DIR}/gpu")
    endif()
    if(NOT GPU_TARGET)
        set(GPU_TARGET gpu_assets)
    endif()

    file(GLOB GPU_ASM_FILES CONFIGURE_DEPENDS "${GPU_SOURCE_DIR}/*.a99")

    if(NOT GPU_ASM_FILES)
        set(CVBASIC_GPU_OUTPUTS "" PARENT_SCOPE)
        set(CVBASIC_GPU_TARGET "" PARENT_SCOPE)
        return()
    endif()

    if(NOT XAS99_SCRIPT)
        message(FATAL_ERROR "GPU .a99 files detected in ${GPU_SOURCE_DIR} but XAS99 assembler was not found. Enable BUILD_TI99_TOOLS or set XAS99_SCRIPT.")
    endif()

    if(GPU_PLETTER AND NOT PLETTER_EXE)
        message(FATAL_ERROR "GPU Pletter compression requested but PLETTER_EXE is not configured.")
    endif()

    file(MAKE_DIRECTORY "${GPU_BUILD_DIR}")
    file(MAKE_DIRECTORY "${GPU_OUTPUT_DIR}")

    if(GPU_PLETTER)
        if(WIN32)
            set(GPU_PLETTER_EXE_PATH "${PLETTER_EXE}.exe")
        else()
            set(GPU_PLETTER_EXE_PATH "${PLETTER_EXE}")
        endif()
    endif()

    set(GPU_OUTPUTS "")

    foreach(GPU_SRC ${GPU_ASM_FILES})
        get_filename_component(GPU_NAME ${GPU_SRC} NAME_WE)
        set(GPU_BIN_BASE "${GPU_BUILD_DIR}/${GPU_NAME}")
        set(GPU_BIN_OUTPUT "${GPU_BIN_BASE}.bin")
        set(GPU_BAS_OUTPUT "${GPU_OUTPUT_DIR}/${GPU_NAME}.bin.bas")

        # Scan for COPY dependencies to ensure rebuilds when included files change
        scan_asm_dependencies("${GPU_SRC}" GPU_ASM_DEPS)
        add_custom_command(
            OUTPUT "${GPU_BIN_OUTPUT}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${GPU_BUILD_DIR}"
            COMMAND ${PYTHON} "${XAS99_SCRIPT}" -b -R -o "${GPU_BIN_OUTPUT}" "${GPU_SRC}"
            DEPENDS ${GPU_ASM_DEPS} ${GPU_TOOL_DEPS}
            WORKING_DIRECTORY "${GPU_SOURCE_DIR}"
            COMMENT "Assembling GPU source ${GPU_NAME}.a99"
            VERBATIM
        )

        add_custom_command(
            OUTPUT "${GPU_BAS_OUTPUT}"
            COMMAND ${PYTHON} "${CMAKE_SOURCE_DIR}/tools/bin2cvb.py" "${GPU_BIN_OUTPUT}" -o "${GPU_BAS_OUTPUT}"
            DEPENDS "${GPU_BIN_OUTPUT}" "${CMAKE_SOURCE_DIR}/tools/bin2cvb.py"
            WORKING_DIRECTORY "${GPU_BUILD_DIR}"
            COMMENT "Converting ${GPU_NAME}.bin to CVBasic data"
            VERBATIM
        )

        list(APPEND GPU_OUTPUTS "${GPU_BAS_OUTPUT}")

        if(GPU_PLETTER)
            set(GPU_PLETTER_OUTPUT_FILE "${GPU_OUTPUT_DIR}/${GPU_NAME}.bin.pletter.bas")
            add_custom_command(
                OUTPUT "${GPU_PLETTER_OUTPUT_FILE}"
                COMMAND ${CMAKE_COMMAND} -E env "PLETTER_EXE=${GPU_PLETTER_EXE_PATH}"
                        ${PYTHON} "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" "${GPU_BAS_OUTPUT}" -o "${GPU_OUTPUT_DIR}"
                DEPENDS "${GPU_BAS_OUTPUT}" "${CMAKE_SOURCE_DIR}/tools/cvpletter.py" ${GPU_TOOL_DEPS}
                WORKING_DIRECTORY "${GPU_OUTPUT_DIR}"
                COMMENT "Pletter compressing GPU data ${GPU_NAME}.bin.bas"
                VERBATIM
            )
            list(APPEND GPU_OUTPUTS "${GPU_PLETTER_OUTPUT_FILE}")
        endif()
    endforeach()

    add_custom_target(${GPU_TARGET} DEPENDS ${GPU_OUTPUTS})

    set(CVBASIC_GPU_OUTPUTS ${GPU_OUTPUTS} PARENT_SCOPE)
    set(CVBASIC_GPU_TARGET ${GPU_TARGET} PARENT_SCOPE)
endfunction()

# Setup CVBasic project configuration
# Call this once at the beginning of your CMakeLists.txt to set project-wide defaults
#
# Parameters:
#   SOURCE_FILE - Main .bas source file
#   SOURCE_DIR - Directory containing source files
#   LIB_DIR - Directory containing library files (optional, defaults to ${SOURCE_DIR}/lib)
#   ASM_DIR - Directory for intermediate assembly files
#   ROMS_DIR - Directory for final ROM files
#   CART_TITLE - Cartridge title (for TI-99 only)
#   VERSION - Version string for ROM filenames (optional)
#   PLETTER_TARGET - Optional pletter compression target to auto-depend on
#   GPU_TARGET - Optional GPU assets target to auto-depend on
#   DEPENDENCIES - List of source file dependencies
#   TOOL_DEPS - List of tool dependencies (from setup_cvbasic_tools)
#
function(cvbasic_setup_project)
    cmake_parse_arguments(PROJ "" "SOURCE_FILE;SOURCE_DIR;LIB_DIR;ASM_DIR;ROMS_DIR;CART_TITLE;VERSION;PLETTER_TARGET;GPU_TARGET" "DEPENDENCIES;TOOL_DEPS" ${ARGN})

    # Set defaults
    if(NOT PROJ_LIB_DIR)
        set(PROJ_LIB_DIR "${PROJ_SOURCE_DIR}/lib")
    endif()

    # Store in parent scope
    set(CVBASIC_PROJECT_SOURCE_FILE "${PROJ_SOURCE_FILE}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_SOURCE_DIR "${PROJ_SOURCE_DIR}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_LIB_DIR "${PROJ_LIB_DIR}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_ASM_DIR "${PROJ_ASM_DIR}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_ROMS_DIR "${PROJ_ROMS_DIR}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_CART_TITLE "${PROJ_CART_TITLE}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_VERSION "${PROJ_VERSION}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_PLETTER_TARGET "${PROJ_PLETTER_TARGET}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_GPU_TARGET "${PROJ_GPU_TARGET}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_DEPENDENCIES "${PROJ_DEPENDENCIES}" PARENT_SCOPE)
    set(CVBASIC_PROJECT_TOOL_DEPS "${PROJ_TOOL_DEPS}" PARENT_SCOPE)
endfunction()

# Simplified CVBasic target builder
# Auto-generates ROM names, ASM names, and descriptions based on platform
#
# Usage:
#   cvbasic_add_target(TARGET_NAME PLATFORM PLATFORM_FLAG [DEFINES defines] [ROM rom_output] [ASM asm_output] [DESCRIPTION desc] [OUTPUT_DIR dir])
#
# Examples:
#   cvbasic_add_target(coleco cv "")
#   cvbasic_add_target(ti99 ti994a --ti994a)
#   cvbasic_add_target(nabu_mame nabu --nabu DEFINES "-DTMS9918_TESTING=1" ROM "000001.nabu" OUTPUT_DIR "${ASM_DIR}")
#
function(cvbasic_add_target TARGET_NAME PLATFORM PLATFORM_FLAG)
    cmake_parse_arguments(TGT "" "DEFINES;ROM;ASM;DESCRIPTION;OUTPUT_DIR" "" ${ARGN})

    # Extract project name from source file
    get_filename_component(PROJECT_NAME "${CVBASIC_PROJECT_SOURCE_FILE}" NAME_WE)

    # Auto-generate ROM name if not provided
    if(NOT TGT_ROM)
        # Map target names to ROM name suffixes
        set(ROM_SUFFIX "${TARGET_NAME}")
        if(TARGET_NAME STREQUAL "coleco")
            set(ROM_SUFFIX "cv")
        elseif(TARGET_NAME STREQUAL "creativision")
            set(ROM_SUFFIX "crv")
        elseif(TARGET_NAME STREQUAL "sg1000")
            set(ROM_SUFFIX "sc3000")
        endif()

        # Build ROM name with platform-specific extension
        if(PLATFORM STREQUAL "cv")
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.rom")
        elseif(PLATFORM STREQUAL "ti994a")
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}_8.bin")
        elseif(PLATFORM STREQUAL "msx")
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.rom")
        elseif(PLATFORM STREQUAL "nabu")
            # NABU is special - no suffix for regular nabu target
            if(TARGET_NAME STREQUAL "nabu")
                set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}.nabu")
            else()
                set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.nabu")
            endif()
        elseif(PLATFORM STREQUAL "sg1000" OR PLATFORM STREQUAL "sc3000")
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.sg")
        elseif(PLATFORM STREQUAL "creativision" OR PLATFORM STREQUAL "crv")
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.bin")
        else()
            set(TGT_ROM "${PROJECT_NAME}_${CVBASIC_PROJECT_VERSION}_${ROM_SUFFIX}.bin")
        endif()
    endif()

    # Auto-generate ASM name if not provided
    if(NOT TGT_ASM)
        get_filename_component(ROM_NAME "${TGT_ROM}" NAME_WE)
        if(PLATFORM_FLAG STREQUAL "--ti994a")
            set(TGT_ASM "${ROM_NAME}.a99")
        else()
            set(TGT_ASM "${ROM_NAME}.asm")
        endif()
    endif()

    # Auto-generate description if not provided
    if(NOT TGT_DESCRIPTION)
        # Platform-specific descriptions
        if(PLATFORM STREQUAL "cv")
            set(TGT_DESCRIPTION "ColecoVision")
        elseif(PLATFORM STREQUAL "ti994a")
            set(TGT_DESCRIPTION "TI-99/4A")
        elseif(PLATFORM STREQUAL "msx")
            # Try to infer MSX type from target name
            if(TARGET_NAME MATCHES "konami")
                set(TGT_DESCRIPTION "MSX Konami")
            elseif(TARGET_NAME MATCHES "asc")
                set(TGT_DESCRIPTION "MSX ASCII16")
            else()
                set(TGT_DESCRIPTION "MSX")
            endif()
        elseif(PLATFORM STREQUAL "nabu")
            if(TARGET_NAME MATCHES "mame")
                set(TGT_DESCRIPTION "NABU MAME")
            else()
                set(TGT_DESCRIPTION "NABU")
            endif()
        elseif(PLATFORM STREQUAL "sc3000" OR PLATFORM STREQUAL "sg1000")
            set(TGT_DESCRIPTION "SG-1000/SC-3000")
        elseif(PLATFORM STREQUAL "crv" OR PLATFORM STREQUAL "creativision")
            set(TGT_DESCRIPTION "CreatiVision")
        else()
            set(TGT_DESCRIPTION "${PLATFORM}")
        endif()
    endif()

    # CVBasic compilation
    set(CVBASIC_COMMAND ${CVBASIC_EXE} ${PLATFORM_FLAG})
    if(TGT_DEFINES)
        list(APPEND CVBASIC_COMMAND ${TGT_DEFINES})
    endif()
    list(APPEND CVBASIC_COMMAND "${CVBASIC_PROJECT_SOURCE_FILE}" "${CVBASIC_PROJECT_ASM_DIR}/${TGT_ASM}" "${CVBASIC_PROJECT_LIB_DIR}")

    # Use JOB_POOL to serialize CVBasic executions (avoids cvbasic_temporary.asm conflicts)
    add_custom_command(
        OUTPUT "${CVBASIC_PROJECT_ASM_DIR}/${TGT_ASM}"
        COMMAND ${CVBASIC_COMMAND}
        DEPENDS ${CVBASIC_PROJECT_DEPENDENCIES} ${CVBASIC_PROJECT_TOOL_DEPS}
        WORKING_DIRECTORY "${CVBASIC_PROJECT_SOURCE_DIR}"
        JOB_POOL cvbasic_pool
        COMMENT "Compiling CVBasic for ${TGT_DESCRIPTION}"
        VERBATIM
    )

    # Determine output directory (use custom if specified, otherwise use roms dir)
    if(TGT_OUTPUT_DIR)
        set(ROM_OUTPUT_DIR "${TGT_OUTPUT_DIR}")
    else()
        set(ROM_OUTPUT_DIR "${CVBASIC_PROJECT_ROMS_DIR}")
    endif()

    # Assembly step (platform specific)
    if(PLATFORM_FLAG STREQUAL "--ti994a")
        cvbasic_assemble_ti99("${TGT_ASM}" "${TGT_ROM}" "${CVBASIC_PROJECT_CART_TITLE}" "${CVBASIC_PROJECT_ASM_DIR}" "${ROM_OUTPUT_DIR}" "${CVBASIC_PROJECT_TOOL_DEPS}")
    else()
        cvbasic_assemble_gasm80("${TGT_ASM}" "${TGT_ROM}" "${CVBASIC_PROJECT_ASM_DIR}" "${ROM_OUTPUT_DIR}" "${CVBASIC_PROJECT_TOOL_DEPS}")
    endif()

    # Add target
    add_custom_target(${TARGET_NAME} DEPENDS "${ROM_OUTPUT_DIR}/${TGT_ROM}")

    # Auto-add pletter compression dependency if configured
    if(CVBASIC_PROJECT_PLETTER_TARGET)
        add_dependencies(${TARGET_NAME} ${CVBASIC_PROJECT_PLETTER_TARGET})
    endif()

    # Auto-add GPU assets dependency if configured
    if(CVBASIC_PROJECT_GPU_TARGET)
        add_dependencies(${TARGET_NAME} ${CVBASIC_PROJECT_GPU_TARGET})
    endif()
endfunction()
