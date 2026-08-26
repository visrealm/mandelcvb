# Helper script to link TI-99 cartridges with optional banking support
# Checks if _b0.bin exists (banked) or uses .bin (non-banked)

message(STATUS "TI-99 Link Helper Debug Info:")
message(STATUS "  ASM_DIR: ${ASM_DIR}")
message(STATUS "  ASM_NAME: ${ASM_NAME}")
message(STATUS "  ROMS_DIR: ${ROMS_DIR}")
message(STATUS "  ROM_OUTPUT: ${ROM_OUTPUT}")
message(STATUS "  PYTHON: ${PYTHON}")
message(STATUS "  LINKTICART_SCRIPT: ${LINKTICART_SCRIPT}")

if(EXISTS "${ASM_DIR}/${ASM_NAME}_b0.bin")
    # Banking detected - use _b0.bin
    set(INPUT_BIN "${ASM_DIR}/${ASM_NAME}_b0.bin")
    message(STATUS "Banking detected for ${ASM_NAME}")
    message(STATUS "  Input: ${INPUT_BIN}")
else()
    # No banking - use regular .bin
    set(INPUT_BIN "${ASM_DIR}/${ASM_NAME}.bin")
    message(STATUS "Non-banked build for ${ASM_NAME}")
    message(STATUS "  Input: ${INPUT_BIN}")
    
    if(NOT EXISTS "${INPUT_BIN}")
        message(FATAL_ERROR "Input .bin file does not exist: ${INPUT_BIN}")
    endif()
endif()

if(NOT EXISTS "${LINKTICART_SCRIPT}")
    message(FATAL_ERROR "linkticart.py script not found: ${LINKTICART_SCRIPT}")
endif()

execute_process(
    COMMAND "${PYTHON}" "${LINKTICART_SCRIPT}"
            "${INPUT_BIN}"
            "${ROMS_DIR}/${ROM_OUTPUT}"
            "${CART_TITLE}"
    WORKING_DIRECTORY "${ASM_DIR}"
    RESULT_VARIABLE LINK_RESULT
    OUTPUT_VARIABLE LINK_OUTPUT
    ERROR_VARIABLE LINK_ERROR
)

if(NOT LINK_RESULT EQUAL 0)
    if(LINK_OUTPUT)
        message(STATUS "linkticart output: ${LINK_OUTPUT}")
    endif()
    if(LINK_ERROR)
        message(STATUS "linkticart error: ${LINK_ERROR}")
    endif()
    message(FATAL_ERROR "Failed to link TI-99 cartridge (exit code: ${LINK_RESULT})")
endif()
