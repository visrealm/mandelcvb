'
' Project: mandelcvb
'
' Common (visrealm) input handling
'
' Copyright (c) 2026 Troy Schrapel
'
' This code is licensed under the MIT license
'
' https://github.com/visrealm/mandelcvb
'

CONST NAV_NONE                  = 0
CONST NAV_DOWN                  = 1
CONST NAV_UP                    = 2
CONST NAV_LEFT                  = 4
CONST NAV_RIGHT                 = 8
CONST NAV_OK                    = 16
CONST NAV_CANCEL                = 32

' every direction bit, i.e. everything that starts a new render
CONST NAV_ANY_DIR               = NAV_DOWN OR NAV_UP OR NAV_LEFT OR NAV_RIGHT

DEF FN NAV(v) =(g_nav AND(v))

' -----------------------------------------------------------------------------
' centralised navigation handling for kb and joystick
' -----------------------------------------------------------------------------
updateNavInput: PROCEDURE
  g_nav = NAV_NONE

  ' <DOWN> or <X>
  IF CONT.DOWN OR(CONT1.KEY = "X") THEN g_nav = g_nav OR NAV_DOWN

  ' <UP> or <E>
  IF CONT.UP OR(CONT1.KEY = "E") THEN g_nav = g_nav OR NAV_UP

  ' <RIGHT> or <D>
  IF CONT.RIGHT OR(CONT1.KEY = "D") THEN g_nav = g_nav OR NAV_RIGHT

  ' <LEFT> or <S>
  IF CONT.LEFT OR(CONT1.KEY = "S") THEN g_nav = g_nav OR NAV_LEFT

  ' <LBUTTON> or <SPACE> or <ENTER>
  IF CONT.BUTTON OR CONT.BUTTON2 OR(CONT1.KEY = " ") OR(CONT1.KEY = 11) THEN g_nav = g_nav OR NAV_OK

  ' Single-key equivalents of the fire chords.
  '
  ' A keyboard cannot reach the chords on the TI-99: the matrix scan in
  ' cvbasic_9900_prologue.asm returns the first pressed key it finds walking
  ' columns 0 to 5, and every modifier - CTRL, SHIFT, FCTN - along with SPACE
  ' sits in column 0. Holding one masks whatever else is down, so SPACE+E
  ' reports SPACE and CTRL+E reports CTRL. Synthesising the chord from one key
  ' costs nothing and leaves the joystick path untouched.
  '
  ' These are no-ops on a keypad-only machine: a ColecoVision returns 0-9, 10
  ' and 11, never a letter.
  IF CONT1.KEY = "I" THEN g_nav = g_nav OR NAV_OK OR NAV_UP        ' zoom in
  IF CONT1.KEY = "O" THEN g_nav = g_nav OR NAV_OK OR NAV_DOWN      ' zoom out
  IF CONT1.KEY = "," THEN g_nav = g_nav OR NAV_OK OR NAV_LEFT      ' <, fewer iterations
  IF CONT1.KEY = "." THEN g_nav = g_nav OR NAV_OK OR NAV_RIGHT     ' >, more iterations
END
