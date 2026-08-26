'
' Project: mandelcvb
'
' Common (visrealm) VDP utilities
'
' Copyright (c) 2026 Troy Schrapel
'
' This code is licensed under the MIT license
'
' https://github.com/visrealm/mandelcvb
'

' VDP constants (CVBasic defaults - only used before the F18A bitmap layer
' takes over the whole of VRAM)
CONST #VDP_PATT_TAB1            = $0000
CONST #VDP_NAME_TAB1            = $1800
CONST #VDP_SPRITE_ATTR          = $1B00
CONST #VDP_COLOR_TAB1           = $2000

' CVBasic loads its built-in 8x8 character set here when a MODE is selected.
' 96 glyphs (ASCII 32..127), 8 bytes each.
CONST #VDP_FONT                 = #VDP_PATT_TAB1 + $0100
CONST #VDP_FONT_SIZE            = $0300
CONST VDP_FONT_FIRST_CHAR       = 32

CONST TILE_SIZE                 = 8

CONST NAME_TABLE_WIDTH          = 32
CONST NAME_TABLE_HEIGHT         = 24

#if TMS9918_TESTING
  DEF FN VDP_REG(VR) = IF (VR < 8) THEN VDP(VR)
  DEF FN VDP_STATUS = 0
#else
  DEF FN VDP_REG(VR) = VDP(VR)
  DEF FN VDP_STATUS = USR RDVST
#endif

DEF FN VDP_CONFIG(I) = VDP_REG(58) = I : VDP_REG(59) ' = xxx
DEF FN VDP_STATUS_REG = VDP_REG(15)
DEF FN VDP_STATUS_REG0 = VDP_STATUS_REG = 0

' VDP helpers
DEF FN VDP_DISABLE_INT = VDP_REG(1) = $C0 OR vdpR1Flags
DEF FN VDP_ENABLE_INT = VDP_REG(1) = $E0 OR vdpR1Flags
DEF FN VDP_DISABLE_INT_DISP_OFF = VDP_REG(1) = $80 OR vdpR1Flags
DEF FN VDP_ENABLE_INT_DISP_OFF = VDP_REG(1) = $A0 OR vdpR1Flags

' name table helpers (text mode only - used for the "no F18A" error screen)
DEF FN XY(X, Y) =((Y) * NAME_TABLE_WIDTH +(X))

' used as a staging area for dynamic vram data (instead of a VPOKE in a loop)
DIM rowBuffer(NAME_TABLE_WIDTH)
DEF FN FILL_BUFFER(val) = CH = val : GOSUB fillBuffer

CH = 0

fillBuffer: PROCEDURE
  FOR J = 0 TO NAME_TABLE_WIDTH - 1 : rowBuffer(J) = CH : NEXT J
END

DIM vdpR1Flags

' -----------------------------------------------------------------------------
' detect the vdp type. sets isF18ACompatible
' -----------------------------------------------------------------------------
vdpDetect: PROCEDURE
  GOSUB vdpUnlock
  DEFINE VRAM $3F00, VARPTR gpuVdpDetectEnd(0) - VARPTR gpuVdpDetect(0), gpuVdpDetect
  VDP_REG($36) = $3F ' set gpu start address msb
  VDP_REG($37) = $00 ' set gpu start address lsb (triggers)
  isF18ACompatible = VPEEK($3F00) = 0 ' check result
  isPICO9918 = FALSE
  IF isF18ACompatible THEN
    VDP_STATUS_REG = 1
    isPICO9918 =((VDP_STATUS AND $e8) = $e8)
    VDP_STATUS_REG0
  END IF
  IF isPICO9918 THEN ' avoid warning
  END IF
END

' -----------------------------------------------------------------------------
' unlock F18A mode
' -----------------------------------------------------------------------------
vdpUnlock: PROCEDURE
  VDP_DISABLE_INT_DISP_OFF
  VDP_REG(57) = $1C ' unlock
  VDP_REG(57) = $1C ' unlock... again
  VDP_ENABLE_INT_DISP_OFF
END

' -----------------------------------------------------------------------------
' block until the GPU has finished the program it is running
' -----------------------------------------------------------------------------
gpuWait: PROCEDURE
  VDP_STATUS_REG = 2
  WHILE VDP_STATUS AND $80
  WEND
  VDP_STATUS_REG0
END

' -----------------------------------------------------------------------------
' non-blocking GPU poll. sets gpuIsBusy (SR2 bit 7 = GPU ST)
' -----------------------------------------------------------------------------
gpuBusyCheck: PROCEDURE
  VDP_STATUS_REG = 2
  gpuIsBusy = VDP_STATUS AND $80
  VDP_STATUS_REG0
END

' -----------------------------------------------------------------------------
' TMS9900 machine code (for the F18A GPU) to write $00 to VDP $3F00
' -----------------------------------------------------------------------------
gpuVdpDetect:
  DATA BYTE $04, $E0    ' CLR  @>3F00
  DATA BYTE $3F, $00
  DATA BYTE $03, $40    ' IDLE
gpuVdpDetectEnd:
