# ROM layout

Source of truth: MAME 0.289 `ROM_START( nost )` (`src/mame/misc/mcatadv.cpp`).
`scripts/romtool.py` is the executable form of this document. No ROM data is in the repository.

## MAME regions

| Region | Size | Contents |
| --- | --- | --- |
| `maincpu` | 0x100000 | `nos-pe-u.bin` even bytes, `nos-po-u.bin` odd bytes (ROM_LOAD16_BYTE) |
| `soundcpu` | 0x040000 | `nos-ps.u9` (Z80; 0x0000-0x7FFF fixed, 16 KB banks at 0x8000) |
| `sprdata` | 0x800000, **erased to 0xFF** | `nos-se-0/so-0` at 0x000000, `se-1/so-1` at 0x200000, `se-2/so-2` (512 KB each) at 0x400000, interleaved even/odd bytes; 0x500000-0x7FFFFF unpopulated (U92/U93) |
| `bg0` | 0x180000 | `nos-b0-0.u58` + `nos-b0-1.u59` (ROM_LOAD) |
| `bg1` | 0x180000 | `nos-b1-0.u60` + `nos-b1-1.u61` |
| `ymsnd:adpcma` | 0x100000 | `nossn-00.u53` |

Verification: `romtool.py regions` == `scripts/mame/dump_regions.lua` output for all six regions,
byte for byte (including the 0xFF fill of `sprdata`).

## ioctl stream (index 0, hps_io WIDE=1)

| Stream offset | Length | Data | Word format (`ioctl_dout`) |
| --- | --- | --- | --- |
| 0x000000 | 0x100000 | `maincpu` | 68000 word `{even, odd}` (MRA map: pe = 10, po = 01) |
| 0x100000 | 0x040000 | `soundcpu` | `{byte 2k+1, byte 2k}` |
| 0x140000 | 0x100000 | `adpcma` | `{byte 2k+1, byte 2k}` |
| 0x240000 | 0x180000 | `bg0` | `{byte 2k+1, byte 2k}` |
| 0x3C0000 | 0x180000 | `bg1` | `{byte 2k+1, byte 2k}` |
| 0x540000 | 0x500000 | `sprdata` 0x000000-0x4FFFFF | `{byte 2k+1, byte 2k}` (MRA map: se = 01, so = 10) |

Total 0xA40000 bytes. `sprdata` 0x500000-0x7FFFFF is not sent: the sprite fetcher returns 0xFF
for it (pen 15 everywhere, as MAME's erased region).

## SDRAM image (byte addresses, 16-bit words, byte 2w = word bits 7-0)

| SDRAM | Data |
| --- | --- |
| 0x0000000-0x00FFFFF | `maincpu` (68000 words as is) |
| 0x0100000-0x013FFFF | `soundcpu` |
| 0x0200000-0x02FFFFF | `adpcma` |
| 0x0400000-0x057FFFF | `bg0`, row-reordered |
| 0x0600000-0x077FFFF | `bg1`, row-reordered |
| 0x0800000-0x0CFFFFF | `sprdata` 0x000000-0x4FFFFF |

Tilemap row reorder: a 16x16 tile (128 bytes, `code*4` + quadrant 8x8 tiles TL, TR, BL, BR, each
`gfx_8x8x4_packed_msb` = 4 bytes per row, high nibble first) is stored as 16 rows of 8 bytes:
row r = 4 bytes of TL/BL row r%8, then 4 bytes of TR/BR. One 4-word SDRAM burst = one 16-pixel
tile row. Sprite data stays linear: one burst = 16 consecutive sprite pixels (low nibble first).
