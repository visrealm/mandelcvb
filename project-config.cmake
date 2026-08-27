# Minimal per-project settings
# Adjust these values to suit your game/demo.

set(PROJECT_NAME mandelcvb)
set(VERSION "v0-0-2")
set(MAIN_SOURCE "mandelcvb.bas")
set(CART_TITLE "MANDELCVB")

# Override CVBasic executable (leave empty to use bundled/default tooling)
# set(CVBASIC_CUSTOM_EXE "C:/projects/CVBasic/build/cvbasic.exe" CACHE FILEPATH "Path to prebuilt CVBasic executable")

# List the platform targets you want built. Removing a target also skips
# downloading/building its toolchain (e.g., TI-99 / XDT99) when possible.
#
# Note: an F18A-compatible VDP (F18A or PICO9918) moves the whole renderer onto
# the VDP's GPU. Without one the host CPU renders in Graphics II instead.
set(ENABLED_TARGETS
    ti99
    coleco
    msx_asc16
    msx_konami
    nabu
    sg1000
    #creativision
    # nabu_mame  # uncomment to enable NABU MAME packaging target
)
