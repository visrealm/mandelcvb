'
' Project: mandelcvb
'
' mandelCVB - DDT's fixed-point Mandelbrot generator, rendered by the F18A GPU.
'
' CVBasic port of the TI-99/4A TMS9900 assembly build (mandelF18A.asm) by DDT:
'   https://github.com/0x444454/mandel99
' For other platforms see also:
'   https://github.com/0x444454/mandelbr8
'
' The Mandelbrot calculation, colour mapping, low-res tile-skip optimisation and
' framebuffer rendering all run on the F18A GPU (src/gpu/mandel-gpu.a99). This
' host program only sets up the F18A, uploads the GPU image, drives the UI, and
' draws text directly into the fat-pixel framebuffer.
'
' The CVBasic host code here is new, but its structure and UI behaviour - and
' the GPU renderer it drives - are ports of DDT's original.
'
' Original work (c) DDT, licensed CC BY 4.0: https://github.com/0x444454/mandel99
' CVBasic port (c) 2026 Troy Schrapel, licensed CC BY 4.0
' https://creativecommons.org/licenses/by/4.0/deed.en
'
' https://github.com/visrealm/mandelcvb
'

' ==========================================
' ENTRY POINT
' ------------------------------------------
GOTO main

CONST FALSE = 0
CONST TRUE  = -1

' No per-frame sprite table copy: VRAM belongs to the bitmap framebuffer.
CONST CVBASIC_DIRECT_SPRITES = 1

' Keep CVBasic's built-in character set. MODE 2 loads it into VRAM at $0100,
' where it survives under the framebuffer and is read back to draw fat-pixel
' text - so no font data has to be duplicated in ROM.
CONST CVBASIC_INCLUDE_FONT = 1

' ==========================================
' INCLUDES
' ------------------------------------------
include "vdp-utils.bas"
include "input.bas"

' Host-CPU fallback, used when no F18A-compatible VDP is present.
include "cpu-core.bas"
include "cpu-render.bas"

' Generated from src/gpu/*.a99 by the build. Included here (ahead of any use)
' because CVBasic is single-pass: the *_SIZE constants must already be defined.
include "gen/gpu/gpu-loader.bin.bas"
include "gen/gpu/mandel-gpu.bin.bas"

' ==========================================
' VRAM LAYOUT
' ------------------------------------------
' $0000-$00FF  (CVBasic pattern table, chars 0..31 - unused)
' $0100-$03FF  CVBasic character set, read back to draw fat-pixel text
' $0400-$09FF  GPU low-res iteration buffer (32*24 words)
' $0A00-$0A0D  host <-> GPU control block (last word = GPU done flag)
' $0A80        sprite attribute table (list terminator only)
' $0AF0-$0AF5  GPU loader parameters
' $0B00-$0B13  GPU bootstrap loader
' $1000-$3FFF  128x192 4-bpp fat-pixel framebuffer (also GPU image staging)
' $4000-$47FF  F18A private GRAM - the Mandelbrot GPU image
' ------------------------------------------
CONST #FP_FB_BASE               = $1000
CONST #GPU_LR_BUF               = $0400

' Host <-> GPU control block. Written as one 14-byte block, so only the base
' address is needed here; the GPU-side names live in src/gpu/mandel-gpu.a99.
CONST #GPU_CTRL_BLOCK           = $0A00
CONST GPU_CTRL_SIZE             = 14
CONST #GPU_ABORT_FLAG           = $0A00
CONST #GPU_DONE                 = $0A0C

' Cleared by the host before every GPU launch, set by the GPU at every exit.
' DEF FN must precede its first use - CVBasic is single-pass.
DEF FN GPU_CLEAR_DONE = VPOKE #GPU_DONE, 0 : VPOKE #GPU_DONE + 1, 0

CONST #SPR_ATTR_BASE            = $0A80
CONST SPR_LIST_END              = $D0

CONST #GPU_LDR_SRC              = $0AF0
CONST #GPU_LDR_DST              = $0AF2
CONST #GPU_LDR_WORDS            = $0AF4
CONST #GPU_LOADER_PC            = $0B00
CONST #GPU_MAIN_PC              = $4000

' The image is staged where the framebuffer will live: it is the only free run
' of VRAM big enough, and it is cleared before the display is switched on.
CONST #GPU_STAGING              = #FP_FB_BASE

' ==========================================
' FAT-PIXEL GEOMETRY
' ------------------------------------------
' 128 logical pixels per line at 4bpp = 64 bytes. A text cell is one 8x8 glyph,
' so 8 fat pixels (4 bytes) wide and 8 framebuffer scanlines high.
CONST FP_ROW_BYTES              = 64
CONST FP_FB_ROWS                = 192
CONST FP_TEXT_COLS              = 16
CONST FP_TEXT_ROWS              = 24
CONST #FP_TEXT_ROW_BYTES        = FP_ROW_BYTES * 8

' Indices into the custom F18A palette below.
CONST FP_BLACK                  = 1
CONST FP_WHITE                  = 9

' Two black pixels in one byte - the framebuffer clear value.
CONST FP_CLEAR_BYTE             = FP_BLACK * 16 + FP_BLACK

' ==========================================
' UI LIMITS
' ------------------------------------------
CONST UI_INC_MIN                = 8       ' deepest zoom
CONST #UI_INC_MAX               = 512     ' default / widest zoom
CONST UI_ITER_MIN               = 1
CONST #UI_ITER_MAX              = 511

' Frames to wait after handling input, so a held key does not race the render.
CONST UI_PAN_DELAY              = 10
CONST UI_FIRE_DELAY             = 6
CONST UI_SPLASH_DELAY           = 120

' ==========================================
' GLOBALS
' ------------------------------------------
DIM gpuParams(GPU_CTRL_SIZE)    ' staging for the shared control block
DIM pcPair(4)                   ' fat-pixel byte for each 2-bit glyph pattern

' ==========================================
' ACTUAL ENTRY POINT
' ------------------------------------------
main:
  MODE 2                        ' Graphics I - loads the character set at $0100
  vdpR1Flags = 0

  ' What are we working with?
  GOSUB vdpDetect
  renderIsGpu = isF18ACompatible
#if HAS_CPU_CORE
  IF isF18ACompatible = FALSE THEN GOTO cpuMain
#else
  IF isF18ACompatible = FALSE THEN GOTO noF18A
#endif

  ' Upload the GPU image while the display is still off-limits to the bitmap
  ' layer, so the staging bytes are never visible.
  GOSUB installGpuImage
  GOSUB setupF18A
  GOSUB clearFatPixels

  ' Welcome screen, drawn straight into the fat-pixel framebuffer.
  pcFg = FP_WHITE
  pcBg = FP_BLACK
  pmX = 0
  pmY = 0
  pmIndex = 0
  GOSUB printMessage

  VDP_ENABLE_INT                ' display on
  FOR uiFrame = 1 TO UI_SPLASH_DELAY : WAIT : NEXT uiFrame

  ' Default logical low-resolution view.
  #uiAx = -2 * 4096
  #uiAy = 6000
  #uiInc = #UI_INC_MAX
  #uiMaxIter = 16
  paramVisible = FALSE

' ------------------------------------------
' RENDER / UI LOOP
' ------------------------------------------
startRender:
  #frameStart = FRAME
  renderPhase = 0
  gpuJob = 0
  GOSUB launchGpuJob

renderWait:
  GOSUB updateNavInput
  IF NAV(NAV_ANY_DIR) THEN GOTO handleInput

  GOSUB gpuPollDone
  IF gpuIsBusy THEN GOTO renderWait

  ' Current GPU job completed.
  IF renderPhase THEN GOTO renderComplete

  ' The low-res pass is done. Redraw any live parameter on the UI before
  ' starting the high-res pass. Since that renders top-to-bottom, the
  ' bottom-right corner keeps the value readable for as long as possible.
  GOSUB drawParamValue
  renderPhase = 1
  gpuJob = 1
  GOSUB launchGpuJob
  GOTO renderWait

renderComplete:
  ' Print elapsed frames as four hex digits in the upper-right corner.
  pcX = FP_TEXT_COLS - 4
  pcY = 0
  pcFg = FP_WHITE
  pcBg = FP_BLACK
  #phWord = FRAME - #frameStart
  GOSUB printHexWord

  ' Don't keep the two-digit parameter on screen - we want only elapsed frames.
  paramVisible = FALSE

idleLoop:
  GOSUB updateNavInput
  IF NAV(NAV_ANY_DIR) = 0 THEN GOTO idleLoop

' ------------------------------------------
' USER INPUT
' ------------------------------------------
handleInput:
  ' If a GPU render is running, ask it to abort. The CPU renderer polls input
  ' itself and has already stopped by the time we get here.
  IF renderIsGpu THEN GOSUB abortGpuJob

  IF NAV(NAV_OK) THEN GOTO inputFire

  ' No FIRE: pan one logical low-res pixel.
  IF NAV(NAV_UP) THEN
    #uiAy = #uiAy + #uiInc
  ELSEIF NAV(NAV_DOWN) THEN
    #uiAy = #uiAy - #uiInc
  END IF

  IF NAV(NAV_LEFT) THEN
    #uiAx = #uiAx - #uiInc
  ELSEIF NAV(NAV_RIGHT) THEN
    #uiAx = #uiAx + #uiInc
  END IF

  uiDelay = UI_PAN_DELAY
  GOTO inputDone

inputFire:
  IF NAV(NAV_UP) THEN
    ' FIRE+UP = zoom in.
    IF #uiInc > UI_INC_MIN THEN
      #uiNewInc = #uiInc / 2
      GOSUB calcZoom
    END IF
    phValue = #uiInc / 4        ' scale for 2-digit display of zoom depth
    GOSUB showParamValue

  ELSEIF NAV(NAV_DOWN) THEN
    ' FIRE+DOWN = zoom out.
    IF #uiInc < #UI_INC_MAX THEN
      #uiNewInc = #uiInc * 2
      GOSUB calcZoom
    END IF
    phValue = #uiInc / 4
    GOSUB showParamValue

  ELSEIF NAV(NAV_LEFT) THEN
    ' FIRE+LEFT = max iterations--.
    IF #uiMaxIter > UI_ITER_MIN THEN #uiMaxIter = #uiMaxIter - 1
    phValue = #uiMaxIter
    GOSUB showParamValue

  ELSEIF NAV(NAV_RIGHT) THEN
    ' FIRE+RIGHT = max iterations++.
    IF #uiMaxIter < #UI_ITER_MAX THEN #uiMaxIter = #uiMaxIter + 1
    phValue = #uiMaxIter
    GOSUB showParamValue
  END IF

  uiDelay = UI_FIRE_DELAY

inputDone:
  FOR uiFrame = 1 TO uiDelay : WAIT : NEXT uiFrame
  IF renderIsGpu THEN GOTO startRender
  GOTO cpuStartRender

' ------------------------------------------
' CPU RENDER / UI LOOP
' ------------------------------------------
' Same view state and input handling as the GPU path; only the renderer differs.
' There is no benchmark readout here - Graphics II has no spare glyph source
' once the bitmap owns the pattern table.
cpuMain:
  GOSUB cpuSetupGraphics2

  #uiAx = -2 * 4096
  #uiAy = 6000
  #uiInc = #UI_INC_MAX
  #uiMaxIter = 16
  paramVisible = FALSE

cpuStartRender:
  cpuAbort = FALSE
  GOSUB cpuRenderLowRes
  IF cpuAbort THEN GOTO handleInput
  GOSUB cpuRenderHiRes
  IF cpuAbort THEN GOTO handleInput

cpuIdleLoop:
  GOSUB updateNavInput
  IF NAV(NAV_ANY_DIR) = 0 THEN GOTO cpuIdleLoop
  GOTO handleInput

' ------------------------------------------
' NO F18A
' ------------------------------------------
' This program is intentionally F18A-only. Make failure visible and stop.
noF18A:
  VDP_REG(7) = $F6              ' white on dark red
  PRINT AT XY(4, 10), "F18A GPU REQUIRED"
  PRINT AT XY(4, 12), "(F18A OR PICO9918)"
  PRINT AT XY(2, 15), "NO CPU CORE FOR THIS CPU"
  WHILE 1 : WAIT : WEND

' ==========================================
' F18A SETUP / GPU CONTROL
' ------------------------------------------

' -----------------------------------------------------------------------------
' Configure the F18A for a 128x192 16-colour fat-pixel bitmap layer.
' Leaves the display off - clearFatPixels runs before it is switched back on.
' -----------------------------------------------------------------------------
setupF18A: PROCEDURE
  VDP_DISABLE_INT_DISP_OFF

  VDP_REG(0) = $00
  VDP_REG(7) = $11              ' palette 1 (black) foreground / backdrop

  ' First 16 programmable colours.
  VDP_REG(47) = $C0             ' palette data port mode, auto-increment, index 0
  DEFINE VRAM 0, 32, paletteF18A
  VDP_REG(47) = $00

  ' No sprites. VR51 = 0 restores the hardware sprite-limit setting; it does not
  ' disable sprite rendering. Put the sprite attribute table outside the
  ' framebuffer and terminate the list immediately with the standard $D0 Y value.
  VDP_REG(5) = #SPR_ATTR_BASE / 128
  VPOKE #SPR_ATTR_BASE, SPR_LIST_END

  ' Bitmap layer: 128x192 logical fat pixels, 16 colours.
  VDP_REG(31) = $F0             ' enabled, priority, transparent, fat pixels
  VDP_REG(32) = #FP_FB_BASE / 64
  VDP_REG(33) = 0               ' X
  VDP_REG(34) = 0               ' Y
  VDP_REG(35) = 0               ' width = 256 physical = 128 fat pixels
  VDP_REG(36) = FP_FB_ROWS      ' height
  VDP_REG(50) = $08             ' disable tile layer while bitmap layer is active
END

' -----------------------------------------------------------------------------
' Install the GPU image into F18A private GRAM.
' The host can only reach ordinary VRAM through the VDP port, so a bootstrap
' running on the GPU itself block-copies the staged image up to $4000.
' -----------------------------------------------------------------------------
installGpuImage: PROCEDURE
  ' Sizes come from the label pair, NOT the generated MANDEL_GPU_SIZE /
  ' GPU_LOADER_SIZE constants: bin2cvb emits them without the # prefix, so
  ' CVBasic silently truncates any value over 255 to 8 bits.
  #gpuSize = VARPTR gpuLoaderEnd(0) - VARPTR gpuLoader(0)
  DEFINE VRAM #GPU_LOADER_PC, #gpuSize, gpuLoader

  #gpuSize = VARPTR mandelGpuEnd(0) - VARPTR mandelGpu(0)
  DEFINE VRAM #GPU_STAGING, #gpuSize, mandelGpu

  ' Loader parameters, big-endian words.
  #gpuWords = #gpuSize / 2
  VPOKE #GPU_LDR_SRC,       #GPU_STAGING / 256
  VPOKE #GPU_LDR_SRC + 1,   #GPU_STAGING AND $FF
  VPOKE #GPU_LDR_DST,       #GPU_MAIN_PC / 256
  VPOKE #GPU_LDR_DST + 1,   #GPU_MAIN_PC AND $FF
  VPOKE #GPU_LDR_WORDS,     #gpuWords / 256
  VPOKE #GPU_LDR_WORDS + 1, #gpuWords AND $FF

  ' Run the bootstrap and wait for it to finish.
  GPU_CLEAR_DONE
  VDP_REG($36) = #GPU_LOADER_PC / 256   ' set gpu start address msb
  VDP_REG($37) = #GPU_LOADER_PC         ' set gpu start address lsb (triggers)
  GOSUB gpuWaitDone
END

' -----------------------------------------------------------------------------
' Start GPU job "gpuJob": 0 = low-res 32x24, 1 = high-res 128x192 refinement.
' -----------------------------------------------------------------------------
launchGpuJob: PROCEDURE
  ' Stream the complete shared control block in one sequential write.
  gpuParams(0) = 0                        ' abort flag: run
  gpuParams(1) = 0
  gpuParams(2) = 0                        ' job
  gpuParams(3) = gpuJob
  gpuParams(4) = #uiAx / 256
  gpuParams(5) = #uiAx AND $FF
  gpuParams(6) = #uiAy / 256
  gpuParams(7) = #uiAy AND $FF
  gpuParams(8) = #uiInc / 256
  gpuParams(9) = #uiInc AND $FF
  gpuParams(10) = #uiMaxIter / 256
  gpuParams(11) = #uiMaxIter AND $FF
  gpuParams(12) = 0                       ' done flag: cleared before launch
  gpuParams(13) = 0
  DEFINE VRAM #GPU_CTRL_BLOCK, GPU_CTRL_SIZE, VARPTR gpuParams(0)

  ' Reset/load PC and start the main GPU program. Clearing the done flag in the
  ' same block write means there is no ambiguous window between the trigger and
  ' the GPU actually starting - the flag reads "not finished" throughout.
  VDP_REG($36) = #GPU_MAIN_PC / 256
  VDP_REG($37) = #GPU_MAIN_PC
END

' -----------------------------------------------------------------------------
' Ask the GPU to stop, then wait until it is idle.
' -----------------------------------------------------------------------------
abortGpuJob: PROCEDURE
  VPOKE #GPU_ABORT_FLAG, $FF
  VPOKE #GPU_ABORT_FLAG + 1, $FF
  GOSUB gpuWaitDone
END

' -----------------------------------------------------------------------------
' GPU completion is published to a VRAM flag rather than read from status
' register 2.
'
' Selecting a non-zero status register (VR15) is not safe here: CVBasic's
' interrupt handler does not read the VDP status itself, it relies on the
' console interrupt routine's read to acknowledge VBlank - and on the F18A a
' read of a non-zero status register does not clear the interrupt flag. DDT's
' original guarded every status read with LIMI 0; a DEF FN sequence in CVBasic
' cannot hold interrupts off across the select/read/restore, so the whole
' mechanism is avoided instead.
' -----------------------------------------------------------------------------
gpuWaitDone: PROCEDURE
  WHILE VPEEK(#GPU_DONE) = 0
  WEND
END

gpuPollDone: PROCEDURE
  gpuIsBusy = VPEEK(#GPU_DONE) = 0
END

' -----------------------------------------------------------------------------
' Fill the fat-pixel framebuffer with black.
' -----------------------------------------------------------------------------
clearFatPixels: PROCEDURE
  FILL_BUFFER(FP_CLEAR_BYTE)
  #cfpAddr = #FP_FB_BASE
  FOR cfpRow = 0 TO FP_FB_ROWS - 1
    DEFINE VRAM #cfpAddr, NAME_TABLE_WIDTH, VARPTR rowBuffer(0)
    DEFINE VRAM #cfpAddr + NAME_TABLE_WIDTH, NAME_TABLE_WIDTH, VARPTR rowBuffer(0)
    #cfpAddr = #cfpAddr + FP_ROW_BYTES
  NEXT cfpRow
END

' ==========================================
' FAT-PIXEL TEXT
' ------------------------------------------

' -----------------------------------------------------------------------------
' Draw one CVBasic character-set glyph into the fat-pixel framebuffer.
' The glyph is read back out of VRAM, so no font data is duplicated in ROM.
'
' Inputs:
'   pcX    text column [0..15]
'   pcY    text row    [0..23]
'   pcChar ASCII code
'   pcFg   foreground palette index
'   pcBg   background palette index
' -----------------------------------------------------------------------------
printChar: PROCEDURE
  ' One packed framebuffer byte per 2-bit glyph pattern: %00 %01 %10 %11.
  pcPair(0) = pcBg * 16 + pcBg
  pcPair(1) = pcBg * 16 + pcFg
  pcPair(2) = pcFg * 16 + pcBg
  pcPair(3) = pcFg * 16 + pcFg

  #pcSrc = #VDP_FONT +(pcChar - VDP_FONT_FIRST_CHAR) * 8
  #pcDst = #FP_FB_BASE + pcY * #FP_TEXT_ROW_BYTES + pcX * 4

  FOR pcRow = 0 TO 7
    pcBits = VPEEK(#pcSrc)
    #pcSrc = #pcSrc + 1

    VPOKE #pcDst, pcPair(pcBits / 64)
    pcBits = pcBits * 4
    VPOKE #pcDst + 1, pcPair(pcBits / 64)
    pcBits = pcBits * 4
    VPOKE #pcDst + 2, pcPair(pcBits / 64)
    pcBits = pcBits * 4
    VPOKE #pcDst + 3, pcPair(pcBits / 64)

    #pcDst = #pcDst + FP_ROW_BYTES
  NEXT pcRow
END

' -----------------------------------------------------------------------------
' Print a $00-terminated string from the messages table. $0D starts a new row.
'
' Inputs:
'   pmIndex  byte offset of the string within messages()
'   pmX/pmY  text origin
'   pcFg/pcBg colours
' -----------------------------------------------------------------------------
printMessage: PROCEDURE
  pcX = pmX
  pcY = pmY
  WHILE 1
    pcChar = messages(pmIndex)
    pmIndex = pmIndex + 1
    IF pcChar = 0 THEN EXIT WHILE
    IF pcChar = 13 THEN
      pcX = pmX
      pcY = pcY + 1
    ELSE
      GOSUB printChar
      pcX = pcX + 1
    END IF
  WEND
END

' -----------------------------------------------------------------------------
' Print phDigit [0..15] as one hexadecimal character at pcX, pcY.
' -----------------------------------------------------------------------------
printHexDigit: PROCEDURE
  IF phDigit < 10 THEN
    pcChar = phDigit + 48       ' '0'
  ELSE
    pcChar = phDigit + 55       ' 'A' - 10
  END IF
  GOSUB printChar
  pcX = pcX + 1
END

' -----------------------------------------------------------------------------
' Print phValue as two hexadecimal characters. Advances pcX by 2.
' -----------------------------------------------------------------------------
printHexByte: PROCEDURE
  phDigit = phValue / 16
  GOSUB printHexDigit
  phDigit = phValue AND $0F
  GOSUB printHexDigit
END

' -----------------------------------------------------------------------------
' Print #phWord as four hexadecimal characters. Advances pcX by 4.
' -----------------------------------------------------------------------------
printHexWord: PROCEDURE
  phValue = #phWord / 256
  GOSUB printHexByte
  phValue = #phWord AND $FF
  GOSUB printHexByte
END

' ==========================================
' UI HELPERS
' ------------------------------------------

' -----------------------------------------------------------------------------
' Remember and show the current zoom increment or max-iteration value as two
' hexadecimal characters, in the bottom-right of the 16x24 fat-pixel text grid.
' Only the low byte of phValue is displayed.
' -----------------------------------------------------------------------------
showParamValue: PROCEDURE
  paramValue = phValue
  paramVisible = TRUE
  GOSUB drawParamValue
END

' -----------------------------------------------------------------------------
' Redraw the remembered parameter value, if one has been selected by the UI.
' Drawn from the key handler and again once the low-res pass completes.
' -----------------------------------------------------------------------------
drawParamValue: PROCEDURE
  IF paramVisible = FALSE THEN RETURN
  pcX = FP_TEXT_COLS - 2
  pcY = FP_TEXT_ROWS - 1
  pcFg = FP_WHITE
  pcBg = FP_BLACK
  phValue = paramValue
  GOSUB printHexByte
END

' -----------------------------------------------------------------------------
' Keep the screen centre fixed when changing the low-res increment.
' Inputs: #uiNewInc = new increment.
' -----------------------------------------------------------------------------
calcZoom: PROCEDURE
  #uiDiff = #uiNewInc - #uiInc
  #uiAx = #uiAx - #uiDiff * 16  ' 32 columns / 2
  #uiAy = #uiAy + #uiDiff * 12  ' 24 rows / 2
  #uiInc = #uiNewInc
END

' ==========================================
' DATA
' ------------------------------------------

' F18A palette: entry 1 is black (the "inside the set" colour) and entries
' 2..F form the escape-time gradient the GPU indexes directly.
paletteF18A:
  DATA BYTE $00, $00            ' 0 transparent / unused
  DATA BYTE $00, $00            ' 1 black
  DATA BYTE $04, $39            ' 2
  DATA BYTE $05, $4B            ' 3
  DATA BYTE $05, $6C            ' 4
  DATA BYTE $05, $7D            ' 5
  DATA BYTE $05, $9F            ' 6
  DATA BYTE $06, $AF            ' 7
  DATA BYTE $0C, $DF            ' 8
  DATA BYTE $0F, $FF            ' 9 white
  DATA BYTE $0F, $E9            ' a
  DATA BYTE $0F, $C4            ' b
  DATA BYTE $0F, $A0            ' c
  DATA BYTE $0F, $80            ' d
  DATA BYTE $0D, $60            ' e
  DATA BYTE $0A, $30            ' f

messages:
  DATA BYTE "DDT'S MANDELBROT", 13
  DATA BYTE "F18A CVBASIC", 13
  DATA BYTE "GPU RENDERING", 0
