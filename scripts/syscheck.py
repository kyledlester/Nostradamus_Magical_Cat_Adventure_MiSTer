#!/usr/bin/env python3
"""Compare frames dumped by sim/tb/tb_system.sv (build/sim/frames/cNNNNN.rgb, 320x224 RGB24, the
displayed frame after vblank NNNNN) with MAME captures (scripts/mame/capture_frames.lua fNNNNN/
pixels.bin = the frame MAME rendered at frame_done(NNNNN)).

  syscheck.py <mame frames dir> <offset> [--fpga build/sim/frames] [--search K] [--png DIR]

MAME frame = FPGA vblank + offset. --search K also tries offsets offset-K..offset+K per frame and
reports the best match (to find the alignment). --png writes side-by-side images of differing
frames.
"""
import argparse, glob, os, re, sys
import numpy as np

W, H = 320, 224


def mame_rgb(d):
    a = np.fromfile(os.path.join(d, "pixels.bin"), dtype=np.uint8).reshape(H, W, 4)
    return a[:, :, [2, 1, 0]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("offset", type=int)
    ap.add_argument("--fpga", default="build/sim/frames")
    ap.add_argument("--search", type=int, default=0)
    ap.add_argument("--png", default=None)
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.fpga, "c*.rgb")))
    ok = bad = 0
    for f in files:
        n = int(re.search(r"c\s*(\d+)\.rgb$", f).group(1))
        raw = np.fromfile(f, dtype=np.uint8)
        if raw.size != W * H * 3:
            print(f"SKIP {f}: {raw.size} bytes (incomplete frame)")
            continue
        fp = raw.reshape(H, W, 3)
        res = []
        for off in range(a.offset - a.search, a.offset + a.search + 1):
            d = os.path.join(a.mame, "f%05d" % (n + off))
            if not os.path.exists(os.path.join(d, "pixels.bin")):
                continue
            diff = int(np.any(fp != mame_rgb(d), axis=-1).sum())
            res.append((diff, off))
        if not res:
            print(f"---  FPGA {n}: no MAME frame")
            continue
        res.sort()
        best = res[0]
        exact = dict((o, dd) for dd, o in res).get(a.offset)
        if exact:
            # MAME converts its bitmap with the palette of the NEXT frame (readout); the FPGA, like
            # the PCB, uses the palette live during scan-out. Retry with MAME's state rendered by the
            # executable spec (refrender.py) using the render-time palette.
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import refrender
            st = refrender.load(os.path.join(a.mame, "f%05d" % (n + a.offset)))
            ref = refrender.to_rgb(refrender.render(st), st["pal"])
            rt = int(np.any(fp != ref, axis=-1).sum())
            if rt == 0:
                print(f"OK   FPGA {n} vs MAME {n + a.offset}: {exact} pixels differ only by MAME's readout-time palette (0 with the render-time palette)")
                ok += 1
                continue
        tag = "OK  " if exact == 0 else "DIFF"
        ok += exact == 0
        bad += exact != 0
        extra = f" (best offset {best[1]}: {best[0]})" if a.search else ""
        print(f"{tag} FPGA {n} vs MAME {n + a.offset}: {exact} pixels differ{extra}")
        if a.png and exact:
            from PIL import Image
            os.makedirs(a.png, exist_ok=True)
            m = mame_rgb(os.path.join(a.mame, "f%05d" % (n + a.offset)))
            Image.fromarray(np.concatenate([fp, m], axis=1)).save(os.path.join(a.png, "cmp%05d.png" % n))
    print(f"{ok}/{ok + bad} frames pixel-exact")
    return 0 if bad == 0 and ok > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
