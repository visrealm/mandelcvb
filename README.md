# mandelCVB

DDT's fixed-point Mandelbrot generator, ported to [CVBasic](https://github.com/visrealm/CVBasic)
and rendered entirely on the F18A GPU.

## Build Status

| Platform | Windows | Linux | macOS |
|----------|---------|-------|-------|
| ROMs | [![](https://github.com/visrealm/mandelcvb/actions/workflows/build-windows.yml/badge.svg)](https://github.com/visrealm/mandelcvb/actions/workflows/build-windows.yml) | [![](https://github.com/visrealm/mandelcvb/actions/workflows/build-linux.yml/badge.svg)](https://github.com/visrealm/mandelcvb/actions/workflows/build-linux.yml) | [![](https://github.com/visrealm/mandelcvb/actions/workflows/build-macos.yml/badge.svg)](https://github.com/visrealm/mandelcvb/actions/workflows/build-macos.yml) |

This is a port of DDT's TI-99/4A TMS9900 assembly build (`mandelF18A.asm`) from
[0x444454/mandel99](https://github.com/0x444454/mandel99). For other platforms
see also [0x444454/mandelbr8](https://github.com/0x444454/mandelbr8).

## Requirements

With an F18A-compatible VDP (F18A or
[PICO9918](https://github.com/visrealm/pico9918)) the whole renderer runs on the
VDP's GPU, in 128x192 with 16 colours.

Without one, the TI-99/4A build falls back to rendering on the host CPU in
Graphics II - 256x192, two colours per 8x1 run. It is far slower, but it is the
same algorithm and the same controls.

The other targets have no CPU core yet (see below) and still require an
F18A-compatible VDP; they print a message and stop if none is found.

The TI-99/4A build additionally needs the 32K RAM expansion (CVBasic's TI-99
target always does).

## Supported devices

* TI-99/4A
* ColecoVision
* MSX
* NABU
* SC-3000/SG-1000

Can be compiled for other CVBasic targets too, provided the machine has an
F18A-compatible VDP.

## Controls

| Input | Action |
|---|---|
| `E` `S` `D` `X` / joystick | Pan one low-res pixel |
| Fire + `E` | Zoom in |
| Fire + `X` | Zoom out |
| Fire + `S` | Fewer iterations |
| Fire + `D` | More iterations |

Fire is the joystick button, `SPACE` or `ENTER`.

After a full render the elapsed frame count is printed as four hex digits in
the top-right corner. While a parameter is being changed, its value is shown as
two hex digits in the bottom-right corner.

## How it works

The host CPU does almost nothing. It configures the F18A, uploads the GPU
image, writes a job request, and polls for completion. Every Mandelbrot
iteration, the colour mapping, the tile-skip optimisation and all framebuffer
writes happen inside the VDP.

Each render is two GPU jobs:

1. **Low-res pass** - a logical 32x24 grid. Each point is calculated once,
   its iteration count stored in a VRAM buffer, and drawn immediately as one
   4x8 block of fat pixels. This gives a fast preview of the whole screen.
2. **High-res pass** - 128x192. Each low-res cell is refined to 4x8
   independent pixels, *unless* all eight of its low-res neighbours have the
   same iteration count, in which case the block is already correct and is
   skipped. Border cells are always refined.

Both passes poll an abort flag in VRAM, so a keypress can cut a render short
without waiting for it to finish. Completion is reported the same way - the GPU
writes a done flag in VRAM, which the host clears as part of the control block
before each launch.

Completion is deliberately *not* read from VDP status register 2, even though
that is where the F18A reports GPU state. Selecting a non-zero status register
means the next read through the status port returns that register - and on the
TI-99 the console interrupt routine reads the status port every frame to
acknowledge VBlank. Reading a non-zero status register does not clear the
interrupt flag, so any interrupt landing inside the select/read/restore window
is never acknowledged. DDT's original wraps every status read in `LIMI 0` for
exactly this reason; a CVBasic `DEF FN` cannot hold interrupts off across the
sequence, so the mechanism is avoided altogether.

Arithmetic is Q4.12 fixed point. The escape test keeps both squares as full
unsigned Q8.24 products so the radius check is exact at the available
precision; the `|zx|`/`|zy|` magnitudes are then reused for the cross product.

### Memory map

The F18A GPU can address VRAM plus 2K of private GRAM at `>4000`. The host can
only reach ordinary VRAM through the VDP port, so the main image is staged in
VRAM and a small bootstrap running on the GPU block-copies it up to `>4000`.

| VRAM | Contents |
|---|---|
| `$0000-$00FF` | CVBasic pattern table, chars 0..31 (unused) |
| `$0100-$03FF` | CVBasic character set - read back to draw fat-pixel text |
| `$0400-$09FF` | GPU low-res iteration buffer (32*24 words) |
| `$0A00-$0A0D` | host &harr; GPU control block (last word = GPU done flag) |
| `$0A80` | sprite attribute table (list terminator only) |
| `$0AF0-$0AF5` | GPU loader parameters |
| `$0B00-$0B13` | GPU bootstrap loader |
| `$1000-$3FFF` | 128x192 4-bpp fat-pixel framebuffer (also GPU image staging) |
| `$4000-$47FF` | F18A private GRAM - the Mandelbrot GPU image |

The framebuffer deliberately starts at `$1000` rather than `$0000`, so
CVBasic's character set survives underneath it at `$0100`. Text is drawn by
reading those glyphs straight back out of VRAM, which is why no font data is
duplicated in ROM. (DDT's original read the TI-99 console GROM font instead -
that is not available on the other CVBasic targets.)

### CPU fallback

`src/cpu-core.bas` evaluates one point in host-CPU assembly; `src/cpu-render.bas`
drives the same two-pass low-res/high-res structure as the GPU path and packs the
result into Graphics II.

The core has to be assembly, per CPU: the Q4.12 iteration needs the high word of
a 16x16 product and CVBasic's `*` is 16->16 only, so a BASIC implementation
would be roughly two orders of magnitude too slow. **Only the TMS9900 core
exists so far** - `HAS_CPU_CORE` is 0 for every other target. The Z80 needs a
shift-add 16x16->32 routine (it has no multiply instruction) called three times
per iteration; the contract to implement is documented in `cpu-core.bas`.

The assembly is inline rather than a linked module because xas99 only accepts
labels in column 1 and CVBasic's `ASM` statement always indents its payload -
so an `ASM` block cannot declare a label on the TI-99 at all. CVBasic labels
*are* emitted in column 1, so every branch target is a CVBasic label and the
assembly jumps to its mangled name. Note the mangling differs by target:
`#mpCx` becomes `cvb__MPCX` under xas99 but `cvb_#MPCX` under gasm80.

Text on the CPU path takes a different route to the same place. `MODE 1` clears
the pattern table, taking CVBasic's character set at `$0100` with it, so the
charset is copied to `$1B80` first, while the VDP is still in MODE 2. From
there a glyph is eight byte copies plus eight colour bytes, since a character
cell maps one-to-one onto a bitmap cell. That pays for both the title screen and
the elapsed-frame count drawn top right when a render completes.

Graphics II VRAM works out as:

| Address | Contents |
| --- | --- |
| `$0000-$17FF` | bitmap |
| `$1800-$1AFF` | name table |
| `$1B00-$1B7F` | sprite attributes (list terminator only) |
| `$1B80-$1E7F` | character set copy, ASCII 32..127 |
| `$2000-$37FF` | colour table, one byte per 8x1 run |
| `$3800-$3DFF` | low-res iteration counts, 32x24 words |

The low-res buffer sits on top of the sprite pattern table, which VR6 puts at
`$3800` in this mode. That is only safe because the sprite attribute list is
terminated on its first entry, so the VDP never fetches a sprite pattern.

## Layout

```
src/mandelcvb.bas     host program: F18A setup, GPU control, UI, fat-pixel text
src/vdp-utils.bas     shared VDP/F18A helpers, VDP detection, GPU wait/poll
src/input.bas         shared keyboard/joystick navigation
src/cpu-core.bas      host-CPU point evaluator (inline assembly, per CPU)
src/cpu-render.bas    host-CPU Graphics II renderer
src/gpu/*.a99         TMS9900 code that runs on the F18A GPU
src/gen/gpu/          generated (gitignored) - see below
```

DDT's original assembly build is not vendored here; read it upstream at
[0x444454/mandel99](https://github.com/0x444454/mandel99).

Every `.a99` under `src/gpu/` is run through:

```
 .a99  --[xas99]-->  .bin  --[bin2cvb]-->  .bin.bas
```

and the resulting `DATA BYTE` tables are included by `mandelcvb.bas`. They are
included near the top of the file, ahead of any use, because CVBasic is
single-pass and the generated `*_SIZE` constants must already be defined.

## Build

```
cmake -B build
cmake --build build --target all_platforms
```

ROMs land in `build/roms`. Individual targets are `ti99`, `coleco`,
`msx_asc16`, `msx_konami`, `nabu`, `sg1000`. Edit `project-config.cmake` to
change which are built - dropping `ti99` also skips fetching XDT99, though the
GPU assembly still needs `xas99` regardless of target.

The build fetches and builds [CVBasic](https://github.com/visrealm/CVBasic)
(visrealm fork), [gasm80](https://github.com/visrealm/gasm80),
[XDT99](https://github.com/endlos99/xdt99) and Pletter on first configure. Set
`-DBUILD_TOOLS_FROM_SOURCE=OFF` to use tools already on `PATH`.

> The visrealm CVBasic fork is required: stock CVBasic 0.8.1 does not emit the
> `CVBASIC_DIRECT_SPRITES` / `CVBASIC_INCLUDE_FONT` assembler symbols the
> prologues test, which breaks the Z80 targets and silently omits the font.

### CVBasic gotchas hit while writing this

* **`CONST` without a `#` prefix is 8 bits and truncates silently.**
  `CONST BIG = 628` compiles to 116 with no warning. This is why the GPU image
  size comes from `VARPTR mandelGpuEnd(0) - VARPTR mandelGpu(0)` rather than
  the `MANDEL_GPU_SIZE` constant `bin2cvb.py` emits - only 116 of 628 bytes
  reached GPU GRAM, and the GPU hit an illegal opcode partway through
  `gpu_calc_color`. A literal `628` in the same position is fine; it is only
  the constant that is narrowed. Watch for this in `tools/bin2cvb.py` output
  for any blob over 255 bytes.
* **CVBasic is single-pass.** A `CONST` must be defined textually before the
  line that reads it, which is why the generated GPU includes sit near the top
  of `mandelcvb.bas` rather than at the bottom with the other data.

## Credits and licence

The Mandelbrot renderer, the fixed-point core and the UI design are the work of
**DDT (0x444454)**:

* Original: **[0x444454/mandel99](https://github.com/0x444454/mandel99)** - the
  TI-99/4A TMS9900 build this is ported from
* Other platforms: **[0x444454/mandelbr8](https://github.com/0x444454/mandelbr8)**

Licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.en). This port is
released under the same licence. Changes made in porting are listed in
[LICENSE](LICENSE) - in short: the host CPU side was reimplemented in CVBasic
for all F18A-capable CVBasic targets, the GPU assembly was relocated but
otherwise left alone, and text now comes from CVBasic's character set rather
than the TI-99 console GROM font.

The shared support code (`src/vdp-utils.bas`, `src/input.bas`, the CMake
tooling) is not derived from the original work and is (c) 2026 Troy Schrapel
under the [MIT](https://opensource.org/licenses/MIT) licence.
