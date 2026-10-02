#!/usr/bin/env python3
"""Nostradamus video reference renderer: MAME 0.289 mcatadv_state::screen_update for nost, from a
frame captured by scripts/mame/capture_frames.lua (docs/VIDEO.md). This is the executable spec the
RTL video path is checked against.

  refrender.py check  <frame dir>...          compare with MAME's pixels (exit 1 on any difference)
  refrender.py png    <frame dir> <out.png>   write the reference image
  refrender.py index  <frame dir> <out.bin>   write the 320x224 palette-index image (u16 LE)

Needs local/regions/{bg0,bg1,sprdata}.bin (romtool.py regions), or $NOST_REGDIR for another set.
"""
import os, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REG = os.environ.get("NOST_REGDIR", os.path.join(ROOT, "local", "regions"))   # e.g. local/catt/regions
W, H = 320, 224

_cache = {}


def region(name):
    if name not in _cache:
        _cache[name] = np.fromfile(os.path.join(REG, name + ".bin"), dtype=np.uint8)
    return _cache[name]


def sprite_nibbles():
    """Sprite data as one nibble per pixel: nibble n = byte n>>1, low nibble first."""
    if "sprnib" not in _cache:
        b = region("sprdata")
        n = np.empty(b.size * 2, dtype=np.uint8)
        n[0::2] = b & 15
        n[1::2] = b >> 4
        _cache["sprnib"] = n
    return _cache["sprnib"]


def be16(path, n=None):
    a = np.fromfile(path, dtype=">u2").astype(np.int64)
    return a if n is None else a[:n]


def load(d):
    return dict(
        pal=be16(os.path.join(d, "palette.bin")),
        pal_next=be16(os.path.join(d, "palette_next.bin")) if os.path.exists(os.path.join(d, "palette_next.bin")) else None,
        vram=[be16(os.path.join(d, "vram0.bin")), be16(os.path.join(d, "vram1.bin"))],
        tm=be16(os.path.join(d, "tmregs.bin")),
        vid=be16(os.path.join(d, "vidregs.bin")),
        vidbuf=be16(os.path.join(d, "vidbuf.bin")),
        spr=be16(os.path.join(d, "sprbuf.bin")),
    )


def sext10(v):
    v &= 0x3FF
    return v - 0x400 if v & 0x200 else v


def tile_layer(st, layer):
    """Per-pixel (palette index, opaque, category) of one 038 layer for the visible area, or None
    if the layer is disabled. tmap038 + draw_tilemap_part (per line scroll, row select/scroll)."""
    r0, r1, r2 = (int(x) for x in st["tm"][layer * 3:layer * 3 + 3])
    if r2 & 0x10:
        return None
    vram = st["vram"][layer]
    gfx = region("bg%d" % layer)
    nelem = gfx.size // 32                      # 8x8 elements (MAME code % elements())
    flipx = not (r0 & 0x8000)
    flipy = not (r1 & 0x8000)
    bank = r2 & 0xF
    idx = np.zeros((H, W), dtype=np.int64)
    opq = np.zeros((H, W), dtype=bool)
    cat = np.zeros((H, W), dtype=np.int64)
    xs = np.arange(W)
    for y in range(H):
        scrollx = (r0 & 0x1FF) - 0x194
        scrolly = (r1 & 0x1FF) - 0x1DF
        if r1 & 0x4000:                         # row select
            scrolly = int(vram[0x800 + ((y + scrolly) & 0x1FF) * 2 + 1]) - y
        if r0 & 0x4000:                         # row scroll
            scrollx += int(vram[0x800 + ((y + scrolly) & 0x1FF) * 2 + 0])
        if flipx:
            scrollx -= 0x19
        if flipy:
            scrolly -= 0x141
        sx = ((319 + scrollx - xs) if flipx else (xs + scrollx)) & 511
        syv = ((223 + scrolly - y) if flipy else (y + scrolly)) & 511
        t = (syv >> 4) * 32 + (sx >> 4)
        w0 = vram[t * 2]
        w1 = vram[t * 2 + 1]
        code8 = (w1 * 4 + ((sx >> 3) & 1) + 2 * ((syv >> 3) & 1)) % nelem
        byte = gfx[code8 * 32 + (syv & 7) * 4 + ((sx & 7) >> 1)].astype(np.int64)
        pix = np.where((sx & 1) == 0, byte >> 4, byte & 15)
        colour = (((w0 >> 8) & 0x3F) + bank * 0x40) % 0x200
        idx[y] = colour * 16 + pix
        opq[y] = pix != 0
        cat[y] = (w0 >> 14) & 3
    return idx, opq, cat


def render(st):
    """Palette-index image (H x W) as MAME draws it."""
    dest = np.full((H, W), 0x3F0, dtype=np.int64)
    pri = np.zeros((H, W), dtype=np.int64)
    layers = [tile_layer(st, 0), tile_layer(st, 1)]
    for i in range(4):
        for L in layers:
            if L is None:
                continue
            idx, opq, cat = L
            m = opq & (cat == i)
            dest[m] = idx[m]
            pri[m] |= 8 | i
    # sprites (draw_sprites): last entry of the selected half first; first opaque pixel masks
    nib = sprite_nibbles()
    spr = st["spr"]
    half = 0x2000 if int(st["vidbuf"][2]) == 1 else 0
    gx = int(st["vid"][0]) - 0x184
    gy = int(st["vid"][1]) - 0x1F1
    for e in range(2047, -1, -1):
        s0, s1, s2, s3 = (int(v) for v in spr[half + e * 4: half + e * 4 + 4])
        if s3 == s0:
            continue
        w = ((s2 >> 12) & 15) * 16
        h = ((s3 >> 12) & 15) * 16
        if w == 0 or h == 0:
            continue
        pen = (s0 & 0x3F00) >> 8
        spri = 8 | (s0 >> 14)
        x = sext10(s2) - gx
        y = sext10(s3) - gy
        if x >= W or y >= H or x + w <= 0 or y + h <= 0:
            continue
        n0 = s1 * 256
        blk = np.take(nib, (n0 + np.arange(w * h)) & 0xFFFFFF).reshape(h, w).astype(np.int64)
        if s0 & 0x40:
            blk = blk[::-1, :]
        if s0 & 0x80:
            blk = blk[:, ::-1]
        x0, x1 = max(x, 0), min(x + w, W)
        y0, y1 = max(y, 0), min(y + h, H)
        b = blk[y0 - y:y1 - y, x0 - x:x1 - x]
        p = pri[y0:y1, x0:x1]
        d = dest[y0:y1, x0:x1]
        draw = ((p & 0x10) == 0) & (b != 0)
        vis = draw & (p < spri)
        d[vis] = b[vis] + pen * 16
        p[draw] |= 0x10
    return dest


def to_rgb(idx, pal):
    w = pal[idx]
    def c5(v):
        return ((v << 3) | (v >> 2)).astype(np.uint8)
    r = c5((w >> 5) & 31)
    g = c5((w >> 10) & 31)
    b = c5(w & 31)
    return np.stack([r, g, b], axis=-1)


def mame_rgb(d):
    a = np.fromfile(os.path.join(d, "pixels.bin"), dtype=np.uint8).reshape(H, W, 4)
    return a[:, :, [2, 1, 0]]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "check":
        bad = 0
        for d in sys.argv[2:]:
            st = load(d)
            idx = render(st)
            got = mame_rgb(d)
            pal = st["pal_next"] if st["pal_next"] is not None else st["pal"]
            diff = np.any(to_rgb(idx, pal) != got, axis=-1)
            n = int(diff.sum())
            if n:
                diff2 = np.any(to_rgb(idx, st["pal"]) != got, axis=-1)
                ys, xs = np.nonzero(diff)
                print(f"DIFF {d}: {n} pixels (with render-time palette: {int(diff2.sum())}), first at x={xs[0]} y={ys[0]}")
                bad += 1
            else:
                print(f"OK   {d}")
        print(f"{len(sys.argv) - 2 - bad}/{len(sys.argv) - 2} frames pixel-exact")
        return 1 if bad else 0
    if cmd == "png":
        from PIL import Image
        st = load(sys.argv[2])
        Image.fromarray(to_rgb(render(st), st["pal"])).save(sys.argv[3])
        return 0
    if cmd == "index":
        render(load(sys.argv[2])).astype("<u2").tofile(sys.argv[3])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
