# Video

Reference: MAME 0.289 `mcatadv_state::screen_update`, `draw_tilemap_part`, `draw_sprites`
(`mcatadv.cpp`) and `tilemap038_device` (`tmap038.cpp`). Executable form: `scripts/refrender.py`
(pixel-exact against MAME on every captured frame). RTL: `rtl/nost/nost_tilemap.sv`,
`nost_sprites.sv`, `nost_video.sv`.

## Raster

| | Value | Status |
| --- | --- | --- |
| MAME logical raster | 320 x 256, visible 320 x 224 (lines 0-223), 60 Hz, vblank 224-255 | MAME approximation |
| FPGA dot clock | 7.004160 MHz = clk_sys / 14 | chosen to reproduce MAME's 15.360 kHz / 60.000 Hz with a 456-dot line |
| FPGA line | 456 dots: active 0-319, HSync 344-376 | MiSTer/CRT choice |
| FPGA frame | 256 lines: active 0-223, VSync 232-234 | MAME's line count; sync placement is a choice |

The PCB has 28 MHz and 16 MHz oscillators; the real dot clock / line length / line count have not
been measured. A 28 MHz / 4 = 7 MHz dot clock would give 59.96 Hz with the same raster. Video is
output unrotated (MAME ROT270): MiSTer's framebuffer rotation is used on HDMI; the analog output is
for a rotated CRT.

## Render instant and buffering

MAME renders the whole frame at vblank start (line 224) from the state at that instant, then copies
sprite RAM and vidregs into their buffers (screen vblank callbacks run after `frame_update`). The
FPGA renders each line during the previous line:

* tile RAM, line RAM, 038 registers, vidregs words 0/1: read live. In attract and gameplay the game
  writes them inside vblank (docs/MAME_REFERENCE.md), so the values seen during lines 0-223 equal
  MAME's render-instant values.
* sprite RAM: the game writes it during the whole frame and flips halves with vidregs word 2. At
  vblank start the FPGA copies the half selected by word 2 (MAME: `== 1` -> second half) into a
  display buffer (2048 clocks, CPU writes to not-yet-copied entries wait) - MAME's buffered copy.
* palette: read live during scan-out (MAME applies the palette when its bitmap is converted, one
  frame later, so palette changes can land one frame apart).

## Tilemaps (two 038 chips)

Per line y and layer (registers r0-r2):

```
scrollx = (r0 & 1FF) - 194          scrolly = (r1 & 1FF) - 1DF
if r1 bit 14 (row select): scrolly = lineram[(y + scrolly) & 1FF].word1 - y
if r0 bit 14 (row scroll): scrollx += lineram[(y + scrolly) & 1FF].word0
flip X (r0 bit 15 = 0): scrollx -= 19, source x = (319 + scrollx - x) & 511, else (x + scrollx) & 511
flip Y (r1 bit 15 = 0): scrolly -= 141, source y = (223 + scrolly - y) & 511, else (y + scrolly) & 511
```

Tile (sy >> 4) * 32 + (sx >> 4): word0 = {category[1:0], colour[5:0], -}, word1 = code. 16x16 tiles
are four 8x8 `gfx_8x8x4_packed_msb` elements code*4 + {TL, TR, BL, BR}; MAME takes the 8x8 code
modulo the region's 0xC000 elements, i.e. code % 0x3000. Pen 0 is transparent. Palette index =
((colour + bank * 0x40) % 0x200) * 16 + pen (bank = r2 & 0xF: layer 0 uses 1, layer 1 uses 3), kept
to 12 bits. r2 bit 4 disables the layer. The game uses only the 16x16 tile RAM (MAME maps no 8x8
RAM for this board), so register 1 bit 13 has no effect.

### Cave 038 engine (OSD *Tilemap engine: Cave 038*)

`rtl/nost/nost_tilemap_cave.sv` drives `rtl/vendor/cave/CaveLayerProcessor.sv` (Arcade-Cave_MiSTer,
unmodified) as an alternative line renderer with the same interface. The module is raster-synchronous;
the adapter steps it through x = -32..319 per line and layer, serving its tile RAM / line RAM / tile ROM
addresses from board RAM and the MAME-order bg copies in SDRAM. Board adaptation is in the inputs only:

* origin: `spriteOffset` 0x182 / 0x1F1 and video size 0x101 / 0x1C1 give MAME's scroll origins
  (normal and flipped); colour bank and the code % 0x3000 wrap are applied outside the module;
* line RAM: the module would read both words at (scrolled line - 1), which on this board shows the
  row-selected background one line low and reads an entry the game never writes on line 0. The adapter
  supplies row select from the scrolled line and row scroll from the selected line (as MAME), and,
  with the 038 flipped, converts the row-select value (rowselect - 2y + 0x19E) because MAME applies the
  flip after row select. Parameter `CAVE_LINE_INDEX = 1` restores the module's own lookup.

Longest line ~4200 of 6384 clocks (the MAME-matched engine: ~2300).

## Sprites

Entry (4 words): w0 = {priority[1:0], pen[5:0], flip X, flip Y, -}, w1 = tile, w2 = {width/16,
-, x[9:0]}, w3 = {height/16, -, y[9:0]} (x, y signed). Pixels are a linear nibble stream:
tile * 256 + row * width + column, low nibble first, in the 8 MB `sprdata` region whose top 3 MB
(empty sockets) read 0xF. Screen position = x + column - (vidreg0 - 0x184), y + row -
(vidreg1 - 0x1F1). Entries with w3 == w0 are skipped. MAME draws the last entry first and an opaque
sprite pixel masks all later ones regardless of its priority; the FPGA scans entries 0..2047 and lets
later opaque pixels overwrite, which gives the same result. An entry identical to the previous hit
is dropped (no effect on the picture; the game parks ~950 identical transparent entries at (0,0)).

## Mixing (MAME priority bitmap semantics)

Background pen 0x3F0. Tiles are drawn category 0..3, layer 0 then layer 1 inside a category, so the
visible tile pixel is the opaque one with the highest (category, layer). The priority value of a
pixel is the OR of `8 | category` of every opaque layer pixel (MAME ORs the priority code). The
sprite pixel is shown when that value < `8 | sprite priority`. Note the OR: a sprite with priority
3 is hidden where layer pixels of categories 1 and 2 overlap (value 0xB), which is MAME's behaviour
and has not been checked against the PCB.

## Flip screen

MAME flips the tilemaps (with the offsets above) but not the sprites (`#if 0` in draw_sprites;
the driver is MACHINE_NO_COCKTAIL), and its row scroll / row select are not adapted. The FPGA does
exactly what MAME does (25 flipped frames pixel-exact). The PCB's flipped picture is unknown.

## Verification

| Check | Result |
| --- | --- |
| `refrender.py check` (Python spec vs MAME) | 101/101 attract frames (990-3990), 25/25 flipped frames pixel-exact |
| `scripts/render_batch.sh` / `sim.sh render` (RTL engines + arbiter + sdram.sv + chip model vs MAME) | 8 attract + 3 flipped frames pixel-exact, no render overrun (busiest line 2561 of 6384 clocks) |
| `RB_ARGS=+CAVE038 scripts/render_batch.sh` (Cave 038 engine) | 86/86 frames (9 attract incl. row scroll + row select, 6 gameplay, 71 consecutive 1490-1560) + 25/25 DIP-flipped + 2 OSD flip-180 pixel-exact, no overrun (busiest line 4204 of 6384) |
