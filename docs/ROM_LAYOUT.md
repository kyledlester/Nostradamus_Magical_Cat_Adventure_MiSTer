# ROM layout

Source of truth: MAME 0.289 `ROM_START( nost )` and `ROM_START( mcatadv )`
(`src/mame/misc/mcatadv.cpp`). `scripts/romtool.py` is the executable form of this document
(`--game nost|mcatadv`). No ROM data is in the repository.

## MAME regions

| Region | Nostradamus (`nost`) | Magical Cat Adventure (`mcatadv`) |
| --- | --- | --- |
| `maincpu` | 0x100000: `nos-pe-u.bin` even bytes, `nos-po-u.bin` odd bytes (ROM_LOAD16_BYTE) | 0x100000: `mca-u30e` even, `mca-u29e` odd |
| `soundcpu` | 0x040000: `nos-ps.u9` (Z80; 0x0000-0x7FFF fixed, 16 KB banks at 0x8000) | 0x020000: `u9.bin` (0x0000-0x3FFF fixed, 32 KB window at 0x4000 from bank * 16 KB) |
| `sprdata` (0x800000, **erased to 0xFF**) | `nos-se-0/so-0` at 0x000000, `se-1/so-1` at 0x200000 (1 MB each), `se-2/so-2` (512 KB each) at 0x400000, interleaved even/odd bytes | `mca-u82/u83` (1 MB each) at 0x000000, `mca-u84/u85` (512 KB each) at 0x200000, `mca-u86e/u87e` (512 KB each) at 0x400000; 0x300000-0x3FFFFF stays 0xFF |
| `bg0` | 0x180000: `nos-b0-0.u58` + `nos-b0-1.u59` (ROM_LOAD) | 0x080000: `mca-u58.bin` |
| `bg1` | 0x180000: `nos-b1-0.u60` + `nos-b1-1.u61` | 0x280000: `mca-u60.bin` + `mca-u61.bin` + `mca-u100` |
| `ymsnd:adpcma` | 0x100000: `nossn-00.u53` | 0x080000: `mca-u53.bin` |

0x500000-0x7FFFFF of `sprdata` is unpopulated in both games. Verification: `romtool.py regions`
== `scripts/mame/dump_regions.lua` output for all six regions of both games, byte for byte
(including the 0xFF fill of `sprdata`).

The tile code wraps at the region's element count (MAME `gfx_element::get_data`), i.e. a 16x16
code modulo region bytes / 128: `nost` 0x3000 for both layers, `mcatadv` 0x1000 (bg0) and 0x5000
(bg1). The attract mode of Magical Cat uses bg1 codes up to 0x49A1.

## ioctl streams

Index 1 (one byte, game select): 00 = Nostradamus, 01 = Magical Cat Adventure.

Index 0 (hps_io WIDE=1). Both games use the same slots; a region smaller than its slot is padded
(MRA `repeat` part) with the region's fill (0, or 0xFF for `sprdata` where MAME's erased region
reads 0xFF). The game is not expected to read the zero padding (past MAME's region ends):

| Stream offset | Length | Data | Word format (`ioctl_dout`) |
| --- | --- | --- | --- |
| 0x000000 | 0x100000 | `maincpu` | 68000 word `{even, odd}` (MRA map: even = 10, odd = 01) |
| 0x100000 | 0x040000 | `soundcpu` (`mcatadv`: 0x20000 + 0x20000 zeros) | `{byte 2k+1, byte 2k}` |
| 0x140000 | 0x100000 | `adpcma` (`mcatadv`: 0x80000 + 0x80000 zeros) | `{byte 2k+1, byte 2k}` |
| 0x240000 | 0x180000 | `bg0` (`mcatadv`: 0x80000 + 0x100000 zeros) | `{byte 2k+1, byte 2k}` |
| 0x3C0000 | 0x180000 | `bg1` 0x000000-0x17FFFF | `{byte 2k+1, byte 2k}` |
| 0x540000 | 0x500000 | `sprdata` 0x000000-0x4FFFFF (`mcatadv`: 0x300000-0x3FFFFF sent as 0xFF) | `{byte 2k+1, byte 2k}` (MRA map: even = 01, odd = 10) |
| 0xA40000 | 0x100000 | `mcatadv` only: `bg1` 0x180000-0x27FFFF | `{byte 2k+1, byte 2k}` |

Total 0xA40000 (`nost`) / 0xB40000 (`mcatadv`) bytes. `sprdata` 0x500000-0x7FFFFF is not sent:
the sprite fetcher returns 0xFF for it (pen 15 everywhere, as MAME's erased region).
`romtool.py mracheck [--game mcatadv]` interprets the MRA and compares its streams with this layout.

## SDRAM image (byte addresses, 16-bit words, byte 2w = word bits 7-0)

| SDRAM | Data |
| --- | --- |
| 0x0000000-0x00FFFFF | `maincpu` (68000 words as is) |
| 0x0100000-0x013FFFF | `soundcpu` |
| 0x0200000-0x02FFFFF | `adpcma` |
| 0x0400000-0x057FFFF | `bg0`, row-reordered |
| 0x0800000-0x0CFFFFF | `sprdata` 0x000000-0x4FFFFF |
| 0x0D00000-0x0F7FFFF | `bg1`, row-reordered (up to 0x280000 bytes) |
| 0x1000000-0x117FFFF | `bg0`, MAME byte order (second copy, written by the loader; read by the Cave 038 engine) |
| 0x1200000-0x147FFFF | `bg1`, MAME byte order (second copy) |

Tilemap row reorder: a 16x16 tile (128 bytes, `code*4` + quadrant 8x8 tiles TL, TR, BL, BR, each
`gfx_8x8x4_packed_msb` = 4 bytes per row, high nibble first) is stored as 16 rows of 8 bytes:
row r = 4 bytes of TL/BL row r%8, then 4 bytes of TR/BR. One 4-word SDRAM burst = one 16-pixel
tile row. The MAME-order copies are made by `nost_loader` from the same stream: the Cave 038
fetches 8 bytes = two 8-pixel rows of one 8x8 quadrant per access. Sprite data stays linear: one
burst = 16 consecutive sprite pixels (low nibble first).
