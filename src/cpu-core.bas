'
' Project: mandelcvb
'
' Host-CPU Mandelbrot point evaluator, Q4.12 fixed point.
'
' This is the fallback used when no F18A-compatible VDP is present. It is the
' same algorithm the GPU runs (src/gpu/mandel-gpu.a99), written once per host
' CPU because CVBasic has no 16x16->32 multiply: the fixed-point core needs the
' high word of each product, and synthesising that from byte-wise partial
' products in BASIC is around two orders of magnitude too slow.
'
' The TMS9900 core is DDT's, lifted from mandel99.asm.
'
' Original work (c) DDT, licensed CC BY 4.0: https://github.com/0x444454/mandel99
' This port (c) 2026 Troy Schrapel, licensed CC BY 4.0
' https://creativecommons.org/licenses/by/4.0/deed.en
'
' https://github.com/visrealm/mandelcvb
'
' ----------------------------------------------------------------------------
' Why the code is inline rather than a linked assembly module:
'
' xas99 only accepts labels in column 1, and CVBasic's ASM statement always
' emits its payload indented by one space - so an ASM block cannot declare a
' label at all on the TI-99. CVBasic labels *are* emitted in column 1, so every
' branch target below is a CVBasic label and the assembly jumps to its mangled
' name (cvb_MPITER and so on). That also removes the need for USR argument
' passing: the core reads and writes the CVBasic variables directly.
'
' Note the symbol spelling differs by target - xas99 rejects '#' in labels so
' CVBasic renames #mpCx to cvb__MPCX there, while gasm80 keeps cvb_#MPCX.
' ----------------------------------------------------------------------------

#if TI994A
CONST HAS_CPU_CORE = 1
#else
CONST HAS_CPU_CORE = 0
#endif

' Point being evaluated, all Q4.12 except the iteration counts.
DIM #mpCx
DIM #mpCy
DIM #mpMaxIter
DIM #mpRem

' -----------------------------------------------------------------------------
' Evaluate one Mandelbrot point.
'
' Inputs:  #mpCx, #mpCy    coordinates, Q4.12
'          #mpMaxIter      iteration limit
' Output:  #mpRem          iterations REMAINING; 0 means the point never escaped
'                          and is inside the set.
'
' Returning the remainder rather than the count is deliberate. On the TMS9900
' every register is spoken for - r10 is CVBasic's stack pointer and r11 the
' return address - so there is none left to hold max_iter across the loop for a
' final subtraction. Callers recover the count as #mpMaxIter - #mpRem.
' -----------------------------------------------------------------------------
mandelPoint: PROCEDURE

#if TI994A

  ' ---------------------------------------------------------------------------
  ' TMS9900. The only hard constraint is r10: it is CVBasic's stack pointer, and
  ' the PROCEDURE epilogue returns via "mov *r10+,r0 / b *r0", so r10 and the
  ' word it points at must survive. Every other register is fair game - r0 is
  ' reloaded from the stack on the way out. The VDP interrupt handler runs in
  ' its own workspace, so nothing here is disturbed by it.
  ' ---------------------------------------------------------------------------
  ASM        mov  @cvb__MPMAXITER,r9    ; r9 = remaining iterations
  ASM        jeq  cvb_MPDONE
  ASM        mov  @cvb__MPCX,r4         ; r4 = cx
  ASM        mov  @cvb__MPCY,r5         ; r5 = cy
  ASM        clr  r6                    ; r6 = stored z^2 real term (without c)
  ASM        clr  r7                    ; r7 = stored z^2 imaginary term

mpIter:
  ' Reconstruct the current z from the stored z^2 terms.
  ASM        a    r4,r6                 ; zx += cx
  ASM        a    r5,r7                 ; zy += cy

  ' Full unsigned Q8.24 squares. Keep the magnitudes in r14/r12: they are reused
  ' by the cross product, and the squares must not be narrowed before the escape
  ' test or values outside the radius-2 circle would wrap.
  ASM        mov  r6,r14
  ASM        abs  r14
  ASM        mov  r14,r0
  ASM        mpy  r14,r0                ; r0:r1 = zx*zx, Q8.24
  ASM        mov  r7,r12
  ASM        abs  r12
  ASM        mov  r12,r2
  ASM        mpy  r12,r2                ; r2:r3 = zy*zy, Q8.24

  ' Escape test: zx^2 + zy^2 >= 4.0. In Q8.24 that is >04000000, so only the
  ' high word matters once the low-word carry has been propagated.
  ASM        mov  r0,r13
  ASM        mov  r1,r15
  ASM        a    r3,r15
  ASM        jnc  cvb_MPNOCARRY
  ASM        inc  r13
mpNoCarry:
  ASM        a    r2,r13
  ASM        ci   r13,>0400
  ASM        jhe  cvb_MPDONE

  ' Inside the circle each square is < 4 and narrows safely to Q4.12:
  ' result = (HI << 4) | (LO >> 12).
  ASM        sla  r0,4
  ASM        srl  r1,12
  ASM        soc  r1,r0                 ; r0 = zx^2, Q4.12
  ASM        sla  r2,4
  ASM        srl  r3,12
  ASM        soc  r3,r2                 ; r2 = zy^2, Q4.12

  ' Save the cross-product sign before zx is overwritten.
  ASM        mov  r6,r8
  ASM        xor  r7,r8                 ; bit 15 set iff the signs differed
  ASM        s    r2,r0
  ASM        mov  r0,r6                 ; next zx = zx^2 - zy^2

  ' Imaginary part: 2*zx*zy. The magnitudes survived the square multiplies, so
  ' no reload or ABS is needed. Narrowing and the doubling fold into one shift:
  ' result = (HI << 5) | (LO >> 11).
  ASM        mpy  r12,r14               ; r14:r15 = |zx*zy|, Q8.24
  ASM        sla  r14,5
  ASM        srl  r15,11
  ASM        soc  r15,r14               ; |2*zx*zy|, Q4.12
  ASM        mov  r14,r7

  ' Duplicate the loop tail so the common positive path pays no extra branch.
  ASM        mov  r8,r8                 ; re-establish flags from the saved sign
  ASM        jlt  cvb_MPNEGXY
  ASM        dec  r9
  ASM        jne  cvb_MPITER
  ASM        jmp  cvb_MPDONE
mpNegXY:
  ASM        neg  r7
  ASM        dec  r9
  ASM        jne  cvb_MPITER

mpDone:
  ASM        mov  r9,@cvb__MPREM

#else

  ' ---------------------------------------------------------------------------
  ' Z80 (and 6502) core: NOT IMPLEMENTED YET.
  '
  ' The Z80 has no multiply instruction, so this needs a shift-add 16x16->32
  ' routine (~640 T-states) called three times per iteration, plus the Q8.24
  ' escape test and the two narrowing shifts - all out of RAM scratch, because
  ' there are nowhere near enough registers to hold the state.
  '
  ' Until that exists, HAS_CPU_CORE stays 0 for these targets and they keep the
  ' current behaviour: detect no F18A, print the requirement, stop.
  '
  ' The contract to implement is exactly the TMS9900 one above:
  '   read  cvb_#MPCX, cvb_#MPCY, cvb_#MPMAXITER
  '   write cvb_#MPREM = iterations remaining (0 = inside the set)
  '   leave SP, IX, IY and the shadow registers alone - CVBasic returns from a
  '   PROCEDURE with a plain RET, so the Z80 stack must be balanced on exit
  ' ---------------------------------------------------------------------------

#endif

END
