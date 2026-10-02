#!/usr/bin/env python3
"""Nostradamus ROM tooling (no ROM data is ever written into the repository).

Reference: MAME 0.289 src/mame/misc/mcatadv.cpp ROM_START( nost ) (docs/ROM_LAYOUT.md).

  romtool.py verify   [--zip Z]            CRC/size check against MAME 0.289
  romtool.py regions  [--zip Z] [--out D]  MAME regions, byte-exact (maincpu.bin, sprdata.bin, ...)
  romtool.py stream   [--zip Z] [--out D]  the ioctl index-0 stream the MRA delivers (nost.rom)
  romtool.py images   [--zip Z] [--out D]  simulation images (SDRAM word image, BRAM hex files)
  romtool.py mra      [--out FILE]         write the MRA
  romtool.py mracheck [--zip Z] [--mra F]  rebuild the stream by interpreting the MRA, compare

Default zip: C:/Users/klest/Downloads/mame/roms/nost.zip. Default output dir: local/.
"""
import argparse, os, sys, zipfile, zlib, xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROMDIR = os.environ.get("NOST_ROMDIR", "C:/Users/klest/Downloads/mame/roms")

# ------------------------------------------------------------------------------------ game data
# ROMS: name -> (size, crc32) from `mame -listxml nost` (0.289).
# REGIONS: name -> (size, fill, [(rom, offset, kind)]); kind "b16" = ROM_LOAD16_BYTE (every 2nd
# byte), "load" = ROM_LOAD. fill = initial byte (sprdata is ROMREGION_ERASEFF).
ROMS = {
    "nos-pe-u.bin": (0x80000, 0x4b080149), "nos-po-u.bin": (0x80000, 0x9e3cd6d9),
    "nos-ps.u9":    (0x40000, 0x832551e9),
    "nos-se-0.u82": (0x100000, 0x9d99108d), "nos-so-0.u83": (0x100000, 0x7df0fc7e),
    "nos-se-1.u84": (0x100000, 0xaad07607), "nos-so-1.u85": (0x100000, 0x83d0012c),
    "nos-se-2.u86": (0x80000, 0xd99e6005),  "nos-so-2.u87": (0x80000, 0xf60e8ef3),
    "nos-b0-0.u58": (0x100000, 0x0214b0f2), "nos-b0-1.u59": (0x80000, 0x3f8b6b34),
    "nos-b1-0.u60": (0x100000, 0xba6fd0c7), "nos-b1-1.u61": (0x80000, 0xdabd8009),
    "nossn-00.u53": (0x100000, 0x3bd1bcbc),
}
REGIONS = {
    "maincpu":  (0x100000, 0x00, [("nos-pe-u.bin", 0, "b16"), ("nos-po-u.bin", 1, "b16")]),
    "soundcpu": (0x040000, 0x00, [("nos-ps.u9", 0, "load")]),
    "sprdata":  (0x800000, 0xFF, [("nos-se-0.u82", 0x000000, "b16"), ("nos-so-0.u83", 0x000001, "b16"),
                                  ("nos-se-1.u84", 0x200000, "b16"), ("nos-so-1.u85", 0x200001, "b16"),
                                  ("nos-se-2.u86", 0x400000, "b16"), ("nos-so-2.u87", 0x400001, "b16")]),
    "bg0":      (0x180000, 0x00, [("nos-b0-0.u58", 0, "load"), ("nos-b0-1.u59", 0x100000, "load")]),
    "bg1":      (0x180000, 0x00, [("nos-b1-0.u60", 0, "load"), ("nos-b1-1.u61", 0x100000, "load")]),
    "adpcma":   (0x100000, 0x00, [("nossn-00.u53", 0, "load")]),
}
# MAME region tags (for the Lua dump comparison)
MAME_TAG = {"maincpu": "maincpu", "soundcpu": "soundcpu", "sprdata": "sprdata",
            "bg0": "bg0", "bg1": "bg1", "adpcma": "ymsnd:adpcma"}

# DIP switches (index 254): 16-bit word, byte 0 = DSW1 bits 15-8 (SW1), byte 1 = DSW2 bits 15-8
# (SW2), as MAME's port values (active low). MAME INPUT_PORTS_START( nost ). Bit numbers below are
# MiSTer DIP bits (0-7 = SW1:1-8, 8-15 = SW2:1-8); ids list settings for raw values 0..2^n-1.
DIPS = [
    ("0,1",    "Lives", "5,4,2,3"),
    ("2,3",    "Difficulty", "Hardest,Hard,Easy,Normal"),
    ("4",      "Flip Screen", "On,Off"),
    ("5",      "Demo Sounds", "Off,On"),
    ("6,7",    "Bonus Life", "None,1000k 2000k,500k 1000k,800k 1500k"),
    ("8,9,10", "Coin A", "Free Play,3C 2C,3C 1C,2C 3C,2C 1C,1C 3C,1C 2C,1C 1C"),
    ("11,12,13", "Coin B", "4C 1C,3C 2C,3C 1C,2C 3C,2C 1C,1C 3C,1C 2C,1C 1C"),
    ("14",     "Unused (SW2:7)", "On,Off"),
    ("15",     "Service Mode", "On,Off"),
]

# ioctl index-0 stream (docs/ROM_LAYOUT.md). (name, stream offset, length, region, kind)
#   kind "be16": 68000 words, ioctl_dout = {even byte, odd byte} (stream byte 2k = odd byte)
#   kind "bytes": region bytes in order (ioctl_dout = {byte 2k+1, byte 2k})
STREAM = [
    ("maincpu",  0x000000, 0x100000, "maincpu",  "be16"),
    ("soundcpu", 0x100000, 0x040000, "soundcpu", "bytes"),
    ("adpcma",   0x140000, 0x100000, "adpcma",   "bytes"),
    ("bg0",      0x240000, 0x180000, "bg0",      "bytes"),
    ("bg1",      0x3C0000, 0x180000, "bg1",      "bytes"),
    ("sprdata",  0x540000, 0x500000, "sprdata",  "bytes"),   # populated part; 500000-7FFFFF = FF
]
STREAM_LEN = 0xA40000

# SDRAM byte addresses (32 MB module). 16-bit SDRAM word w holds stream bytes {2w+1, 2w} as
# ioctl_dout delivers them, except the tilemap regions whose 16x16 tiles are stored as 16 rows of
# 8 bytes (two 8x8 tiles side by side), see gfx_row_perm().
SDRAM_BASE = {"maincpu": 0x0000000, "soundcpu": 0x0100000, "adpcma": 0x0200000,
              "bg0": 0x0400000, "bg1": 0x0600000, "sprdata": 0x0800000}
SDRAM_LEN = 0x1000000
# second copy of bg0 / bg1 in MAME byte order for the Cave 038 engine (rtl/nost/nost_tilemap_cave.sv)
SDRAM_CAVE_BG = {"bg0": 0x0D00000, "bg1": 0x0E80000}


def gfx_row_perm(o):
    """Byte offset inside a tilemap region -> SDRAM offset. A 16x16 tile (128 bytes) is four 8x8
    gfx_8x8x4_packed_msb tiles TL, TR, BL, BR (tmap038: code*4 ^ x-half ^ 2*y-half), 4 bytes per
    8-pixel row. Stored as row r (0..15) = 8 bytes: TL/BL row bytes 0-3, then TR/BR bytes 0-3."""
    q = (o >> 5) & 3
    row8 = (o >> 2) & 7
    b = o & 3
    r = (q >> 1) * 8 + row8
    return (o & ~0x7F) | (r << 3) | ((q & 1) << 2) | b


def load_zip(path):
    if not os.path.exists(path):
        raise SystemExit(f"missing {path}")
    z = zipfile.ZipFile(path)
    names = {i.filename.lower(): i.filename for i in z.infolist()}
    data = {}
    for n in ROMS:
        if n not in names:
            raise SystemExit(f"missing {n} in {path}")
        data[n] = z.read(names[n])
    return data


def verify(data):
    ok = True
    for n, (size, crc) in ROMS.items():
        d = data[n]
        c = zlib.crc32(d) & 0xffffffff
        good = len(d) == size and c == crc
        ok &= good
        print(f"{'OK ' if good else 'BAD'} {n:13s} size {len(d):#08x} crc {c:08x} (expect {size:#08x} {crc:08x})")
    return ok


def build_regions(data):
    regs = {}
    for name, (size, fill, loads) in REGIONS.items():
        r = bytearray([fill]) * size
        for rom, off, kind in loads:
            d = data[rom]
            if kind == "b16":
                r[off:off + 2 * len(d):2] = d
            else:
                r[off:off + len(d)] = d
        regs[name] = bytes(r)
    return regs


def build_stream(regs):
    s = bytearray(STREAM_LEN)
    for name, soff, length, src, kind in STREAM:
        d = regs[src][:length]
        if kind == "be16":
            b = bytearray(length)
            b[0::2] = d[1::2]
            b[1::2] = d[0::2]
            d = bytes(b)
        s[soff:soff + length] = d
    return bytes(s)


def build_sdram(regs):
    """SDRAM as a bytearray of little-endian 16-bit words (byte 2w = word bits 7-0), exactly what
    the loader writes (stream word k -> SDRAM)."""
    mem = bytearray(SDRAM_LEN)
    stream = build_stream(regs)
    for name, soff, length, src, kind in STREAM:
        base = SDRAM_BASE[name]
        chunk = stream[soff:soff + length]
        if name in ("bg0", "bg1"):
            out = bytearray(length)
            for o in range(0, length, 2):
                p = gfx_row_perm(o)
                out[p:p + 2] = chunk[o:o + 2]
            chunk = bytes(out)
        mem[base:base + length] = chunk
        if name in SDRAM_CAVE_BG:
            c = SDRAM_CAVE_BG[name]
            mem[c:c + length] = stream[soff:soff + length]
    return mem


def write_hex16(path, words):
    with open(path, "w") as f:
        f.write("\n".join(f"{w:04x}" for w in words))
        f.write("\n")


def write_hex8(path, data):
    with open(path, "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data))
        f.write("\n")


# ---------------------------------------------------------------------------------------- MRA
def make_mra():
    L = []
    a = L.append
    a("<!--")
    a("  Nostradamus - Face 1993 - MRA for the Nostradamus MiSTer core.")
    a("  MAME set nost (MAME 0.289 misc/mcatadv.cpp). No ROM data is embedded in this file.")
    a("  Generated by scripts/romtool.py mra ; layout documented in docs/ROM_LAYOUT.md.")
    a("")
    a("  ioctl index 0 stream (hps_io WIDE=1):")
    for name, soff, length, src, kind in STREAM:
        a(f"    {soff:06X}-{soff + length - 1:06X}  {name:9s} MAME region '{MAME_TAG[src]}' "
          f"({'68000 words' if kind == 'be16' else 'bytes in order'})")
    a("  sprdata 500000-7FFFFF (unpopulated sockets U92/U93, MAME ROMREGION_ERASEFF) is not sent:")
    a("  the core returns FF for it.")
    a("")
    a("  DIP switches (index 254): byte 0 = DSW1 (SW1:1-8 = bits 0-7), byte 1 = DSW2 (SW2:1-8),")
    a("  MAME port values (active low). Default FF,FF = MAME defaults.")
    a("-->")
    a("<misterromdescription>")
    a("    <name>Nostradamus</name>")
    a("    <setname>nost</setname>")
    a("    <rbf>Nostradamus</rbf>")
    a("    <mameversion>0289</mameversion>")
    a("    <year>1993</year>")
    a("    <manufacturer>Face</manufacturer>")
    a("    <category>Shooter</category>")
    a("    <players>2</players>")
    a("    <joystick>8-way</joystick>")
    a("    <rotation>vertical (ccw)</rotation>")
    a('    <buttons names="Shot,Button 2,Button 3,Start,Coin,Service,Pause" default="A,B,X,Start,Select,R,L"/>')
    a("")
    a('    <switches default="FF,FF" base="16">')
    for bits, name, ids in DIPS:
        a(f'        <dip bits="{bits}" name="{name}" ids="{ids}"/>')
    a("    </switches>")
    a("")
    a('    <rom index="0" zip="nost.zip" md5="None">')
    for name, soff, length, src, kind in STREAM:
        a(f"        <!-- {soff:06X} {name} -->")
        loads = REGIONS[src][2]
        if all(k == "load" for _, _, k in loads):
            for rom, off, k in loads:
                a(f'        <part name="{rom}" crc="{ROMS[rom][1]:08x}"/>')
            continue
        pairs = {}
        for rom, off, k in loads:
            pairs.setdefault(off & ~1, [None, None])[off & 1] = rom
        for base in sorted(pairs):
            even, odd = pairs[base]
            # be16: even byte -> ioctl_dout[15:8] (output byte 1); bytes: even -> output byte 0
            me, mo = ("10", "01") if kind == "be16" else ("01", "10")
            a('        <interleave output="16">')
            a(f'            <part name="{even}" crc="{ROMS[even][1]:08x}" map="{me}"/>')
            a(f'            <part name="{odd}" crc="{ROMS[odd][1]:08x}" map="{mo}"/>')
            a("        </interleave>")
    a("    </rom>")
    a("</misterromdescription>")
    return "\n".join(L) + "\n"


def interpret_mra(mra_path, data):
    """Independent MRA interpreter (MiSTer semantics: map digit i from the right = output byte i,
    digit value = input byte number (1-based), 0 = not written). Returns {index: bytes}."""
    root = ET.parse(mra_path).getroot()
    streams = {}

    def part_bytes(p):
        if p.get("repeat"):
            return bytes.fromhex(p.text.strip()) * int(p.get("repeat"), 0)
        if p.get("name") is None:
            return bytes.fromhex(p.text.strip())
        d = data[p.get("name")]
        if (zlib.crc32(d) & 0xffffffff) != int(p.get("crc"), 16):
            raise SystemExit(f"MRA crc mismatch for {p.get('name')}")
        off = int(p.get("offset", "0"), 0)
        ln = int(p.get("length", str(len(d) - off)), 0)
        return d[off:off + ln]

    for rom in root.findall("rom"):
        out = bytearray()
        for el in rom:
            if el.tag == "part":
                out += part_bytes(el)
            elif el.tag == "interleave":
                width = int(el.get("output")) // 8
                parts = [(part_bytes(p), p.get("map")) for p in el.findall("part")]
                n = len(parts[0][0])
                block = bytearray(n * width)
                for d, m in parts:
                    digits = [int(c) for c in reversed(m)]    # digits[i] -> output byte i
                    inw = max(digits)
                    for k in range(n // inw):
                        for i, dg in enumerate(digits):
                            if dg:
                                block[k * width + i] = d[k * inw + dg - 1]
                out += block
        streams[int(rom.get("index"))] = bytes(out)
    return streams


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--zip", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--mra", default=None)
    a = ap.parse_args()
    mra = a.mra or os.path.join(ROOT, "mra", "Nostradamus.mra")
    if a.cmd == "mra":
        path = a.out or mra
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", newline="\n").write(make_mra())
        print("wrote", path)
        return 0
    data = load_zip(a.zip or os.path.join(ROMDIR, "nost.zip"))
    out = a.out or os.path.join(ROOT, "local")
    os.makedirs(out, exist_ok=True)
    if a.cmd == "verify":
        return 0 if verify(data) else 1
    if not verify(data):
        return 1
    regs = build_regions(data)
    if a.cmd == "regions":
        d = os.path.join(out, "regions")
        os.makedirs(d, exist_ok=True)
        for n, r in regs.items():
            open(os.path.join(d, n + ".bin"), "wb").write(r)
        print("regions written to", d)
    elif a.cmd == "stream":
        s = build_stream(regs)
        open(os.path.join(out, "nost.rom"), "wb").write(s)
        print(f"stream {len(s):#x} bytes crc {zlib.crc32(s) & 0xffffffff:08x}")
    elif a.cmd == "images":
        d = os.path.join(out, "sim")
        os.makedirs(d, exist_ok=True)
        mem = build_sdram(regs)
        open(os.path.join(d, "sdram_le.bin"), "wb").write(mem)
        be = bytearray(len(mem))                    # 16-bit words big-endian (SDRAM chip model)
        be[0::2] = mem[1::2]
        be[1::2] = mem[0::2]
        open(os.path.join(d, "sdram_be.bin"), "wb").write(be)
        mc = regs["maincpu"]
        write_hex16(os.path.join(d, "maincpu.hex"), [(mc[2 * i] << 8) | mc[2 * i + 1] for i in range(len(mc) // 2)])
        write_hex8(os.path.join(d, "soundcpu.hex"), regs["soundcpu"])
        write_hex8(os.path.join(d, "adpcma.hex"), regs["adpcma"])
        z = regs["soundcpu"][:0x8000]                 # nost_sound block-RAM copy of 0000-7FFF
        write_hex8(os.path.join(d, "zfix_lo.hex"), z[0::2])
        write_hex8(os.path.join(d, "zfix_hi.hex"), z[1::2])
        print("simulation images written to", d)
    elif a.cmd == "mracheck":
        got = interpret_mra(mra, data)
        want = build_stream(regs)
        s0 = got.get(0, b"")
        if s0 != want:
            n = min(len(s0), len(want))
            first = next((i for i in range(n) if s0[i] != want[i]), n)
            print(f"FAIL mracheck: len {len(s0):#x} vs {len(want):#x}, first difference at {first:#x}")
            return 1
        print(f"PASS mracheck nost: MRA stream == layout stream ({len(s0):#x} bytes, crc "
              f"{zlib.crc32(s0) & 0xffffffff:08x})")
    else:
        ap.error("unknown command")
    return 0


if __name__ == "__main__":
    sys.exit(main())
