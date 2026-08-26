'
' Project: mandelcvb
'
' Host-CPU Mandelbrot renderer for plain TMS9918A machines (Graphics II).
'
' Used when no F18A-compatible VDP is found. Same two-pass structure as the GPU
' path - a 32x24 low-res pass, then a 256x192 refinement that skips low-res
' cells whose eight neighbours all agree - but every point is evaluated by
' mandelPoint (src/cpu-core.bas) on the host CPU.
'
' Original work (c) DDT, licensed CC BY 4.0: https://github.com/0x444454/mandel99
' This port (c) 2026 Troy Schrapel, licensed CC BY 4.0
' https://creativecommons.org/licenses/by/4.0/deed.en
'
' https://github.com/visrealm/mandelcvb
'

' ==========================================
' GRAPHICS II VRAM LAYOUT (CVBasic MODE 1)
' ------------------------------------------
' $0000-$17FF  bitmap / pattern table
' $1800-$1AFF  name table (0..255 repeated three times)
' $1B00-$1B7F  sprite attribute table (list terminator only)
' $1B80-$1E7F  charset copy, ASCII 32..127               <- ours
' $2000-$37FF  colour table, one byte per 8x1 pixel run
' $3800-$3DFF  low-res buffer, 32*24 words               <- ours
'
' The low-res buffer sits on top of the sprite pattern table, which VR6 puts at
' $3800 in this mode. That is safe only because the sprite attribute list below
' is terminated on the first entry, so the VDP never fetches a sprite pattern.
' ------------------------------------------
CONST #CPU_BITMAP               = $0000
CONST #CPU_COLOR                = $2000
CONST #CPU_LR_BUF               = $3800
CONST #CPU_SPR_ATTR             = $1B00
CONST #CPU_FONT                 = $1B80
CONST #CPU_FONT_BYTES           = 768

CONST CPU_TILE_COLS             = 32
CONST CPU_TILE_ROWS             = 24

' Text colours: white on black.
CONST CPU_TEXT_FG               = 15
CONST CPU_TEXT_BG               = 1

' Bytes from one 8x8 cell to the cell below it.
CONST #CPU_CELL_ROW             = 256

' Word offsets between neighbouring low-res cells, for the skip test.
CONST CPU_LR_W                  = 2
CONST CPU_LR_ROW                = 64

DIM cpuCol(8)                   ' colours of the 8 pixels in one 8x1 run
DIM cpuHist(16)                 ' colour histogram for that run

' -----------------------------------------------------------------------------
' Iterations -> TMS9918 colour.
'
' Hand-picked approximation of the F18A gradient the GPU path uses: deep blue
' through cyan and white to yellow and red. Points that never escaped are black,
' matching palette entry 1 on the F18A side.
' -----------------------------------------------------------------------------
cpuGradient:
  DATA BYTE 4, 4, 5, 5, 7, 7, 15, 15, 11, 11, 10, 9, 8, 6

' -----------------------------------------------------------------------------
' Convert #mpRem (iterations remaining) to a colour in cpuColour.
' -----------------------------------------------------------------------------
cpuColourFromRem: PROCEDURE
  IF #mpRem = 0 THEN
    cpuColour = 1                       ' never escaped - inside the set
  ELSE
    cpuColour = cpuGradient((#mpMaxIter - #mpRem) % 14)
  END IF
END

' -----------------------------------------------------------------------------
' Switch the VDP to Graphics II and clear it to black.
' -----------------------------------------------------------------------------
cpuSetupGraphics2: PROCEDURE
  MODE 1
  vdpR1Flags = 0
  VDP_DISABLE_INT_DISP_OFF

  VDP_REG(7) = $01                      ' black backdrop
  VPOKE #CPU_SPR_ATTR, $D0              ' terminate the sprite list

  ' MODE 1 leaves the bitmap cleared, so every pixel reads as "background".
  ' Painting both nibbles black means a cell shows black whatever the bitmap
  ' holds, which is what the low-res pass relies on.
  FILL_BUFFER($11)
  #cpuAddr = #CPU_COLOR
  FOR cpuI = 0 TO 191
    DEFINE VRAM #cpuAddr, NAME_TABLE_WIDTH, VARPTR rowBuffer(0)
    #cpuAddr = #cpuAddr + NAME_TABLE_WIDTH
  NEXT cpuI

  VDP_ENABLE_INT
END

' -----------------------------------------------------------------------------
' Low-res pass: 32x24 cells, each drawn as one solid 8x8 block.
'
' Because the bitmap is all zeroes, writing colour c into both nibbles of the
' cell's eight colour bytes fills the whole block with c. The iteration count is
' kept in VRAM for the refinement pass to consult.
' -----------------------------------------------------------------------------
cpuRenderLowRes: PROCEDURE
  #mpMaxIter = #uiMaxIter
  #cpuLrPtr = #CPU_LR_BUF
  #cpuCy = #uiAy
  #cpuCellAddr = #CPU_COLOR

  FOR cpuRow = 0 TO CPU_TILE_ROWS - 1
    #mpCy = #cpuCy
    #cpuCx = #uiAx

    FOR cpuTx = 0 TO CPU_TILE_COLS - 1
      #mpCx = #cpuCx
      GOSUB mandelPoint

      VPOKE #cpuLrPtr, #mpRem / 256
      VPOKE #cpuLrPtr + 1, #mpRem AND $FF
      #cpuLrPtr = #cpuLrPtr + 2

      GOSUB cpuColourFromRem
      cpuByte = cpuColour * 17          ' same colour in both nibbles

      #cpuAddr = #cpuCellAddr + cpuTx * 8
      FOR cpuI = 0 TO 7
        VPOKE #cpuAddr + cpuI, cpuByte
      NEXT cpuI

      #cpuCx = #cpuCx + #uiInc
    NEXT cpuTx

    #cpuCy = #cpuCy - #uiInc
    #cpuCellAddr = #cpuCellAddr + #CPU_CELL_ROW

    GOSUB updateNavInput
    IF NAV(NAV_ANY_DIR) THEN
      cpuAbort = TRUE
      EXIT FOR
    END IF
  NEXT cpuRow
END

' -----------------------------------------------------------------------------
' Read the low-res iteration count at #cpuLrPtr + (cpuNbr * 2) into #cpuNbrVal.
' -----------------------------------------------------------------------------
cpuReadLr: PROCEDURE
  #cpuAddr = #cpuLrPtr + #cpuNbr
  #cpuNbrVal = VPEEK(#cpuAddr) * 256 + VPEEK(#cpuAddr + 1)
END

' -----------------------------------------------------------------------------
' Refinement pass: 256x192.
'
' Each low-res cell becomes 8x8 individually evaluated pixels, unless all eight
' of its neighbours share its iteration count - in which case the solid block
' the low-res pass drew is already correct. Border cells are always refined.
'
' Graphics II allows only two colours per 8x1 run, so each run is reduced to the
' two commonest of its eight colours and every pixel snapped to whichever of
' those it matches.
' -----------------------------------------------------------------------------
cpuRenderHiRes: PROCEDURE
  #mpMaxIter = #uiMaxIter

  ' One high-res pixel is an eighth of a low-res cell in both axes.
  #cpuIncX = #uiInc / 8
  #cpuIncY = #uiInc / 8
  #cpuHalf = #uiInc / 2

  #cpuLrPtr = #CPU_LR_BUF
  #cpuCellAddr = 0
  #cpuTileCy = #uiAy + #cpuHalf

  FOR cpuTy = 0 TO CPU_TILE_ROWS - 1
    #cpuTileCx = #uiAx - #cpuHalf

    FOR cpuTx = 0 TO CPU_TILE_COLS - 1
      cpuSkip = FALSE

      ' Interior cells may be skippable; edges never are.
      IF cpuTx > 0 AND cpuTx < CPU_TILE_COLS - 1 AND cpuTy > 0 AND cpuTy < CPU_TILE_ROWS - 1 THEN
        #cpuNbr = 0
        GOSUB cpuReadLr
        #cpuCentre = #cpuNbrVal
        cpuSkip = TRUE
        FOR cpuI = 0 TO 7
          #cpuNbr = #cpuNbrOffset(cpuI)
          GOSUB cpuReadLr
          IF #cpuNbrVal <> #cpuCentre THEN
            cpuSkip = FALSE
            EXIT FOR
          END IF
        NEXT cpuI
      END IF

      IF cpuSkip = FALSE THEN
        #cpuCy = #cpuTileCy

        FOR cpuLine = 0 TO 7
          #mpCy = #cpuCy
          #cpuCx = #cpuTileCx

          ' Evaluate the eight pixels of this run and build their histogram.
          FOR cpuI = 0 TO 15 : cpuHist(cpuI) = 0 : NEXT cpuI
          FOR cpuI = 0 TO 7
            #mpCx = #cpuCx
            GOSUB mandelPoint
            GOSUB cpuColourFromRem
            cpuCol(cpuI) = cpuColour
            cpuHist(cpuColour) = cpuHist(cpuColour) + 1
            #cpuCx = #cpuCx + #cpuIncX
          NEXT cpuI

          ' Commonest colour becomes the foreground.
          cpuTop0 = 1
          cpuBest = 0
          FOR cpuI = 1 TO 15
            IF cpuHist(cpuI) > cpuBest THEN
              cpuBest = cpuHist(cpuI)
              cpuTop0 = cpuI
            END IF
          NEXT cpuI
          cpuHist(cpuTop0) = 0

          ' Next commonest becomes the background. If the run is a single
          ' colour this stays equal to the foreground, which is harmless.
          cpuTop1 = cpuTop0
          cpuBest = 0
          FOR cpuI = 1 TO 15
            IF cpuHist(cpuI) > cpuBest THEN
              cpuBest = cpuHist(cpuI)
              cpuTop1 = cpuI
            END IF
          NEXT cpuI

          ' Set a bit for every pixel that matched the foreground.
          cpuBits = 0
          cpuMask = 128
          FOR cpuI = 0 TO 7
            IF cpuCol(cpuI) = cpuTop0 THEN cpuBits = cpuBits + cpuMask
            cpuMask = cpuMask / 2
          NEXT cpuI

          #cpuAddr = #cpuCellAddr + cpuTx * 8 + cpuLine
          VPOKE #CPU_BITMAP + #cpuAddr, cpuBits
          VPOKE #CPU_COLOR + #cpuAddr, cpuTop0 * 16 + cpuTop1

          #cpuCy = #cpuCy - #cpuIncY
        NEXT cpuLine
      END IF

      #cpuLrPtr = #cpuLrPtr + 2
      #cpuTileCx = #cpuTileCx + #uiInc

      GOSUB updateNavInput
      IF NAV(NAV_ANY_DIR) THEN
        cpuAbort = TRUE
        EXIT FOR
      END IF
    NEXT cpuTx

    IF cpuAbort THEN EXIT FOR

    #cpuCellAddr = #cpuCellAddr + #CPU_CELL_ROW
    #cpuTileCy = #cpuTileCy - #uiInc
  NEXT cpuTy
END

' =============================================================================
' TEXT
' =============================================================================
' In Graphics II a character cell maps one-to-one onto a bitmap cell, so drawing
' a glyph is eight byte copies plus eight colour bytes. The only difficulty is
' the glyph source: MODE 1 clears the pattern table, taking CVBasic's charset at
' $0100 with it. cpuCopyFont stashes what we need above the low-res buffer
' first, so it has to run while the VDP is still in MODE 2.
' -----------------------------------------------------------------------------

' -----------------------------------------------------------------------------
' Copy the whole MODE 2 charset - ASCII 32..127, 768 bytes - into the gap above
' the sprite attribute table.
' -----------------------------------------------------------------------------
cpuCopyFont: PROCEDURE
  #cpuSrc = #VDP_FONT
  #cpuAddr = #CPU_FONT
  WHILE #cpuAddr < #CPU_FONT + #CPU_FONT_BYTES
    VPOKE #cpuAddr, VPEEK(#cpuSrc)
    #cpuSrc = #cpuSrc + 1
    #cpuAddr = #cpuAddr + 1
  WEND
END

' -----------------------------------------------------------------------------
' Draw cpuChar at cell (cpuX, cpuY) in cpuFg on cpuBg.
' -----------------------------------------------------------------------------
cpuPrintChar: PROCEDURE
  #cpuSrc = #CPU_FONT +(cpuChar - VDP_FONT_FIRST_CHAR) * 8
  #cpuAddr = cpuY * #CPU_CELL_ROW + cpuX * 8
  cpuAttr = cpuFg * 16 + cpuBg
  FOR cpuI = 0 TO 7
    VPOKE #CPU_BITMAP + #cpuAddr + cpuI, VPEEK(#cpuSrc + cpuI)
    VPOKE #CPU_COLOR + #cpuAddr + cpuI, cpuAttr
  NEXT cpuI
END

' -----------------------------------------------------------------------------
' Draw the null-terminated string at cpuMessages(cpuMsgIdx), origin
' (cpuMsgX, cpuMsgY). Byte 13 starts a new line back at cpuMsgX.
' -----------------------------------------------------------------------------
cpuPrintMessage: PROCEDURE
  cpuX = cpuMsgX
  cpuY = cpuMsgY
  WHILE 1
    cpuChar = cpuMessages(cpuMsgIdx)
    cpuMsgIdx = cpuMsgIdx + 1
    IF cpuChar = 0 THEN EXIT WHILE
    IF cpuChar = 13 THEN
      cpuX = cpuMsgX
      cpuY = cpuY + 1
    ELSE
      GOSUB cpuPrintChar
      cpuX = cpuX + 1
    END IF
  WEND
END

' -----------------------------------------------------------------------------
' Draw #cpuHexVal as four hex digits at (cpuX, cpuY), advancing cpuX.
' -----------------------------------------------------------------------------
cpuPrintHexWord: PROCEDURE
  cpuHexByte = #cpuHexVal / 256
  GOSUB cpuPrintHexByte
  cpuHexByte = #cpuHexVal AND $FF
  GOSUB cpuPrintHexByte
END

cpuPrintHexByte: PROCEDURE
  cpuNib = cpuHexByte / 16
  GOSUB cpuPrintHexNibble
  cpuNib = cpuHexByte AND $0F
  GOSUB cpuPrintHexNibble
END

cpuPrintHexNibble: PROCEDURE
  IF cpuNib < 10 THEN
    cpuChar = cpuNib + 48
  ELSE
    cpuChar = cpuNib + 55
  END IF
  GOSUB cpuPrintChar
  cpuX = cpuX + 1
END

' Splash text. The GPU path has its own copy in mandelcvb.bas - the strings
' differ, and so does the renderer that draws them.
cpuMessages:
  DATA BYTE "DDT's MANDELBROT", 13
  DATA BYTE "TMS9918A", 13
  DATA BYTE "CPU RENDERING", 13
  DATA BYTE "PORT BY VISREALM", 0

' Signed byte offsets from a cell to its eight neighbours, in the low-res
' buffer: W, E, NW, N, NE, SW, S, SE. 16-bit because they are negative.
#cpuNbrOffset:
  DATA -CPU_LR_W, CPU_LR_W
  DATA -CPU_LR_ROW - CPU_LR_W, -CPU_LR_ROW, -CPU_LR_ROW + CPU_LR_W
  DATA CPU_LR_ROW - CPU_LR_W, CPU_LR_ROW, CPU_LR_ROW + CPU_LR_W
