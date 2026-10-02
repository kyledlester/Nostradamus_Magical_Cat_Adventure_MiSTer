#!/usr/bin/env python3
"""LINDA board ROM tooling: Nostradamus and Magical Cat Adventure (no ROM data is ever written into
the repository).

Reference: MAME 0.289 src/mame/misc/mcatadv.cpp ROM_START( nost ) / ROM_START( mcatadv )
(docs/ROM_LAYOUT.md).

  romtool.py verify   [--game G] [--zip Z]            CRC/size check against MAME 0.289
  romtool.py regions  [--game G] [--zip Z] [--out D]  MAME regions, byte-exact (maincpu.bin, ...)
  romtool.py stream   [--game G] [--zip Z] [--out D]  the ioctl index-0 stream the MRA delivers
  romtool.py images   [--game G] [--zip Z] [--out D]  simulation images (SDRAM word image, BRAM hex)
  romtool.py mra      [--game G] [--out FILE]         write the MRA
  romtool.py mracheck [--game G] [--zip Z] [--mra F]  rebuild the stream by interpreting the MRA

--game nost (default) or mcatadv. Default zip: C:/Users/klest/Downloads/mame/roms/<set>.zip.
Default output dir: local/ (nost) or local/mcatadv/ (mcatadv).
"""
import argparse, os, sys, zipfile, zlib, xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROMDIR = os.environ.get("NOST_ROMDIR", "C:/Users/klest/Downloads/mame/roms")

# ------------------------------------------------------------------------------------ game data
# roms: name -> (size, crc32) from `mame -listxml <set>` (0.289).
# regions: name -> (size, fill, [(rom, offset, kind)]); kind "b16" = ROM_LOAD16_BYTE (every 2nd
# byte), "load" = ROM_LOAD. fill = initial byte (sprdata is ROMREGION_ERASEFF).
# dips (index 254): 16-bit word, byte 0 = DSW1 bits 15-8 (SW1), byte 1 = DSW2 bits 15-8 (SW2), as
# MAME's port values (active low). Bit numbers are MiSTer DIP bits (0-7 = SW1:1-8, 8-15 = SW2:1-8);
# ids list settings for raw values 0..2^n-1.
# Stream (docs/ROM_LAYOUT.md): both games share the slot layout of the first 0xA40000 bytes
# (COMMON_STREAM; a region smaller than its slot is padded with the region's fill, which is also
# what MAME reads there); "extra" entries follow it (Magical Cat's larger bg1 region).
# mod: ioctl index 1 byte (game select in the core: 0 = Nostradamus, 1 = Magical Cat Adventure).
GAMES = {
    "nost": {
        "title": "Nostradamus", "year": "1993", "manufacturer": "Face", "category": "Shooter",
        "rotation": "vertical (ccw)", "mod": 0x00,
        "buttons": ("Shot,Button 2,Button 3,Start,Coin,Service,Pause", "A,B,X,Start,Select,R,L"),
        "roms": {
            "nos-pe-u.bin": (0x80000, 0x4b080149), "nos-po-u.bin": (0x80000, 0x9e3cd6d9),
            "nos-ps.u9":    (0x40000, 0x832551e9),
            "nos-se-0.u82": (0x100000, 0x9d99108d), "nos-so-0.u83": (0x100000, 0x7df0fc7e),
            "nos-se-1.u84": (0x100000, 0xaad07607), "nos-so-1.u85": (0x100000, 0x83d0012c),
            "nos-se-2.u86": (0x80000, 0xd99e6005),  "nos-so-2.u87": (0x80000, 0xf60e8ef3),
            "nos-b0-0.u58": (0x100000, 0x0214b0f2), "nos-b0-1.u59": (0x80000, 0x3f8b6b34),
            "nos-b1-0.u60": (0x100000, 0xba6fd0c7), "nos-b1-1.u61": (0x80000, 0xdabd8009),
            "nossn-00.u53": (0x100000, 0x3bd1bcbc),
        },
        "regions": {
            "maincpu":  (0x100000, 0x00, [("nos-pe-u.bin", 0, "b16"), ("nos-po-u.bin", 1, "b16")]),
            "soundcpu": (0x040000, 0x00, [("nos-ps.u9", 0, "load")]),
            "sprdata":  (0x800000, 0xFF, [("nos-se-0.u82", 0x000000, "b16"), ("nos-so-0.u83", 0x000001, "b16"),
                                          ("nos-se-1.u84", 0x200000, "b16"), ("nos-so-1.u85", 0x200001, "b16"),
                                          ("nos-se-2.u86", 0x400000, "b16"), ("nos-so-2.u87", 0x400001, "b16")]),
            "bg0":      (0x180000, 0x00, [("nos-b0-0.u58", 0, "load"), ("nos-b0-1.u59", 0x100000, "load")]),
            "bg1":      (0x180000, 0x00, [("nos-b1-0.u60", 0, "load"), ("nos-b1-1.u61", 0x100000, "load")]),
            "adpcma":   (0x100000, 0x00, [("nossn-00.u53", 0, "load")]),
        },
        "dips": [
            ("0,1",    "Lives", "5,4,2,3"),
            ("2,3",    "Difficulty", "Hardest,Hard,Easy,Normal"),
            ("4",      "Flip Screen", "On,Off"),
            ("5",      "Demo Sounds", "Off,On"),
            ("6,7",    "Bonus Life", "None,1000k 2000k,500k 1000k,800k 1500k"),
            ("8,9,10", "Coin A", "Free Play,3C 2C,3C 1C,2C 3C,2C 1C,1C 3C,1C 2C,1C 1C"),
            ("11,12,13", "Coin B", "4C 1C,3C 2C,3C 1C,2C 3C,2C 1C,1C 3C,1C 2C,1C 1C"),
            ("14",     "Unused (SW2:7)", "On,Off"),
            ("15",     "Service Mode", "On,Off"),
        ],
        "stream_len": 0xA40000,
        "extra": [],
    },
    "mcatadv": {
        "title": "Magical Cat Adventure", "year": "1993", "manufacturer": "Wintechno",
        "category": "Platform", "rotation": "horizontal", "mod": 0x01,
        "buttons": ("Fire,Jump,Button 3 (test),Start,Coin,Service,Pause", "A,B,X,Start,Select,R,L"),
        "roms": {
            "mca-u30e":    (0x80000, 0xc62fbb65), "mca-u29e":    (0x80000, 0xcf21227c),
            "u9.bin":      (0x20000, 0xfda05171),
            "mca-u82.bin": (0x100000, 0x5f01d746), "mca-u83.bin": (0x100000, 0x4e1be5a6),
            "mca-u84.bin": (0x80000, 0xdf202790),  "mca-u85.bin": (0x80000, 0xa85771d2),
            "mca-u86e":    (0x80000, 0x017bf1da),  "mca-u87e":    (0x80000, 0xbc9dc9b9),
            "mca-u58.bin": (0x80000, 0x3a8186e2),
            "mca-u60.bin": (0x100000, 0xc8942614), "mca-u61.bin": (0x100000, 0x51af66c9),
            "mca-u100":    (0x80000, 0xb273f1b0),
            "mca-u53.bin": (0x80000, 0x64c76e05),
        },
        "regions": {
            "maincpu":  (0x100000, 0x00, [("mca-u30e", 0, "b16"), ("mca-u29e", 1, "b16")]),
            "soundcpu": (0x020000, 0x00, [("u9.bin", 0, "load")]),
            "sprdata":  (0x800000, 0xFF, [("mca-u82.bin", 0x000000, "b16"), ("mca-u83.bin", 0x000001, "b16"),
                                          ("mca-u84.bin", 0x200000, "b16"), ("mca-u85.bin", 0x200001, "b16"),
                                          ("mca-u86e", 0x400000, "b16"), ("mca-u87e", 0x400001, "b16")]),
            "bg0":      (0x080000, 0x00, [("mca-u58.bin", 0, "load")]),
            "bg1":      (0x280000, 0x00, [("mca-u60.bin", 0, "load"), ("mca-u61.bin", 0x100000, "load"),
                                          ("mca-u100", 0x200000, "load")]),
            "adpcma":   (0x080000, 0x00, [("mca-u53.bin", 0, "load")]),
        },
        "dips": [
            ("0",      "Demo Sounds", "Off,On"),
            ("1",      "Flip Screen", "On,Off"),
            ("2",      "Service Mode", "On,Off"),
            ("3",      "Coin Mode", "Mode 2,Mode 1"),
            ("4,5",    "Coin A (Mode 1/2)", "2C3C/4C1C,2C1C/3C1C,1C2C/1C4C,1C1C"),
            ("6,7",    "Coin B (Mode 1/2)", "2C3C/4C1C,2C1C/3C1C,1C2C/1C4C,1C1C"),
            ("8,9",    "Difficulty", "Hardest,Hard,Easy,Normal"),
            ("10,11",  "Lives", "5,2,4,3"),
            ("12,13",  "Energy", "8,5,4,3"),
            ("14,15",  "Cabinet", "Upright 2P,Upright 1P,Cocktail,Upright 2P"),
        ],
        "stream_len": 0xB40000,
        "extra": [("bg1 tail", 0xA40000, 0x100000, "bg1", 0x180000, "bytes")],
    },
}
# (name, stream offset, length, region, region offset, kind). kind "be16": 68000 words, ioctl_dout =
# {even byte, odd byte} (stream byte 2k = odd byte); "bytes": region bytes in order
# (ioctl_dout = {byte 2k+1, byte 2k}).
COMMON_STREAM = [
    ("maincpu",  0x000000, 0x100000, "maincpu",  0, "be16"),
    ("soundcpu", 0x100000, 0x040000, "soundcpu", 0, "bytes"),
    ("adpcma",   0x140000, 0x100000, "adpcma",   0, "bytes"),
    ("bg0",      0x240000, 0x180000, "bg0",      0, "bytes"),
    ("bg1",      0x3C0000, 0x180000, "bg1",      0, "bytes"),
    ("sprdata",  0x540000, 0x500000, "sprdata",  0, "bytes"),   # 500000-7FFFFF = FF, not sent
]
# MAME region tags (for the Lua dump comparison)
MAME_TAG = {"maincpu": "maincpu", "soundcpu": "soundcpu", "sprdata": "sprdata",
            "bg0": "bg0", "bg1": "bg1", "adpcma": "ymsnd:adpcma"}

# SDRAM byte addresses (32 MB module). 16-bit SDRAM word w holds stream bytes {2w+1, 2w} as
# ioctl_dout delivers them, except the tilemap regions whose 16x16 tiles are stored as 16 rows of
# 8 bytes (two 8x8 tiles side by side), see gfx_row_perm(). The bg slots hold up to 0x180000 (bg0)
# and 0x280000 (bg1) bytes.
SDRAM_BASE = {"maincpu": 0x0000000, "soundcpu": 0x0100000, "adpcma": 0x0200000,
              "bg0": 0x0400000, "bg1": 0x0D00000, "sprdata": 0x0800000}
SDRAM_LEN = 0x1480000
# second copy of bg0 / bg1 in MAME byte order for the Cave 038 engine (rtl/nost/nost_tilemap_cave.sv)
SDRAM_CAVE_BG = {"bg0": 0x1000000, "bg1": 0x1200000}


def stream_of(game):
    return COMMON_STREAM + GAMES[game]["extra"]


def gfx_row_perm(o):
    """Byte offset inside a tilemap region -> SDRAM offset. A 16x16 tile (128 bytes) is four 8x8
    gfx_8x8x4_packed_msb tiles TL, TR, BL, BR (tmap038: code*4 ^ x-half ^ 2*y-half), 4 bytes per
    8-pixel row. Stored as row r (0..15) = 8 bytes: TL/BL row bytes 0-3, then TR/BR bytes 0-3."""
    q = (o >> 5) & 3
    row8 = (o >> 2) & 7
    b = o & 3
    r = (q >> 1) * 8 + row8
    return (o & ~0x7F) | (r << 3) | ((q & 1) << 2) | b


def load_zip(game, path):
    if not os.path.exists(path):
        raise SystemExit(f"missing {path}")
    z = zipfile.ZipFile(path)
    names = {i.filename.lower(): i.filename for i in z.infolist()}
    data = {}
    for n in GAMES[game]["roms"]:
        if n.lower() not in names:
            raise SystemExit(f"missing {n} in {path}")
        data[n] = z.read(names[n.lower()])
    return data


def verify(game, data):
    ok = True
    for n, (size, crc) in GAMES[game]["roms"].items():
        d = data[n]
        c = zlib.crc32(d) & 0xffffffff
        good = len(d) == size and c == crc
        ok &= good
        print(f"{'OK ' if good else 'BAD'} {n:13s} size {len(d):#08x} crc {c:08x} (expect {size:#08x} {crc:08x})")
    return ok


def build_regions(game, data):
    regs = {}
    for name, (size, fill, loads) in GAMES[game]["regions"].items():
        r = bytearray([fill]) * size
        for rom, off, kind in loads:
            d = data[rom]
            if kind == "b16":
                r[off:off + 2 * len(d):2] = d
            else:
                r[off:off + len(d)] = d
        regs[name] = bytes(r)
    return regs


def stream_chunk(game, regs, src, roff, length):
    """length bytes of region src from roff, padded with the region's fill past its end."""
    fill = GAMES[game]["regions"][src][1]
    d = regs[src][roff:roff + length]
    return d + bytes([fill]) * (length - len(d))


def build_stream(game, regs):
    s = bytearray(GAMES[game]["stream_len"])
    for name, soff, length, src, roff, kind in stream_of(game):
        d = stream_chunk(game, regs, src, roff, length)
        if kind == "be16":
            b = bytearray(length)
            b[0::2] = d[1::2]
            b[1::2] = d[0::2]
            d = bytes(b)
        s[soff:soff + length] = d
    return bytes(s)


def build_sdram(game, regs):
    """SDRAM as a bytearray of little-endian 16-bit words (byte 2w = word bits 7-0), exactly what
    the loader writes (stream word k -> SDRAM)."""
    mem = bytearray(SDRAM_LEN)
    stream = build_stream(game, regs)
    for name, soff, length, src, roff, kind in stream_of(game):
        base = SDRAM_BASE[src] + roff
        chunk = stream[soff:soff + length]
        if src in ("bg0", "bg1"):
            out = bytearray(length)
            for o in range(0, length, 2):
                p = gfx_row_perm(o)
                out[p:p + 2] = chunk[o:o + 2]
            mem[base:base + length] = out
            c = SDRAM_CAVE_BG[src] + roff
            mem[c:c + length] = chunk
        else:
            mem[base:base + length] = chunk
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
def mra_segments(game, src, roff, length, kind):
    """MRA elements producing region src [roff, roff + length) in stream order: ROM parts (whole
    or offset/length), 16-bit interleaves of ROM_LOAD16_BYTE pairs, and fill repeats."""
    size, fill, loads = GAMES[game]["regions"][src]
    roms = GAMES[game]["roms"]
    pieces = []                       # (start, end, rom name or (even, odd) pair)
    pairs = {}
    for rom, off, k in loads:
        if k == "b16":
            pairs.setdefault(off & ~1, [None, None])[off & 1] = rom
        else:
            pieces.append((off, off + roms[rom][0], rom))
    for base, (even, odd) in pairs.items():
        pieces.append((base, base + 2 * roms[even][0], (even, odd)))
    pieces.sort(key=lambda p: p[0])
    out, pos, end = [], roff, roff + length
    for s, e, what in pieces:
        if e <= pos or s >= end:
            continue
        if s > pos:
            out.append(f'<part repeat="{s - pos:#x}">{fill:02X}</part>')
            pos = s
        if isinstance(what, tuple):
            if s < pos or e > end:
                raise SystemExit("partial interleave not supported")
            even, odd = what
            # be16: even byte -> ioctl_dout[15:8] (output byte 1); bytes: even -> output byte 0
            me, mo = ("10", "01") if kind == "be16" else ("01", "10")
            out += ['<interleave output="16">',
                    f'    <part name="{even}" crc="{roms[even][1]:08x}" map="{me}"/>',
                    f'    <part name="{odd}" crc="{roms[odd][1]:08x}" map="{mo}"/>',
                    '</interleave>']
            pos = e
        else:
            a, b = pos - s, min(e, end) - s
            attrs = ""
            if a or b != e - s:
                attrs = f' offset="{a:#x}" length="{b - a:#x}"'
            out.append(f'<part name="{what}" crc="{roms[what][1]:08x}"{attrs}/>')
            pos = s + b
    if pos < end:
        out.append(f'<part repeat="{end - pos:#x}">{fill:02X}</part>')
    return out


def make_mra(game):
    g = GAMES[game]
    L = []
    a = L.append
    a("<!--")
    a(f"  {g['title']} - {g['manufacturer']} {g['year']} - MRA for the LINDA board MiSTer core")
    a("  (Nostradamus / Magical Cat Adventure; core file Nostradamus).")
    a(f"  MAME set {game} (MAME 0.289 misc/mcatadv.cpp). No ROM data is embedded in this file.")
    a("  Generated by scripts/romtool.py mra ; layout documented in docs/ROM_LAYOUT.md.")
    a("")
    a("  ioctl index 0 stream (hps_io WIDE=1):")
    for name, soff, length, src, roff, kind in stream_of(game):
        rs, fill = g["regions"][src][0], g["regions"][src][1]
        pad = f", {fill:02X} past {rs:#x}" if roff + length > rs and src != "sprdata" else ""
        a(f"    {soff:06X}-{soff + length - 1:06X}  {name:9s} MAME region '{MAME_TAG[src]}' from {roff:#x} "
          f"({'68000 words' if kind == 'be16' else 'bytes in order'}{pad})")
    a("  sprdata 500000-7FFFFF (MAME ROMREGION_ERASEFF, no ROMs) is not sent: the core returns FF.")
    a(f"  ioctl index 1: game select byte {g['mod']:02X}.")
    a("")
    a("  DIP switches (index 254): byte 0 = DSW1 (SW1:1-8 = bits 0-7), byte 1 = DSW2 (SW2:1-8),")
    a("  MAME port values (active low). Default FF,FF = MAME defaults.")
    a("-->")
    a("<misterromdescription>")
    a(f"    <name>{g['title']}</name>")
    a(f"    <setname>{game}</setname>")
    a("    <rbf>Nostradamus</rbf>")
    a("    <mameversion>0289</mameversion>")
    a(f"    <year>{g['year']}</year>")
    a(f"    <manufacturer>{g['manufacturer']}</manufacturer>")
    a(f"    <category>{g['category']}</category>")
    a("    <players>2</players>")
    a("    <joystick>8-way</joystick>")
    a(f"    <rotation>{g['rotation']}</rotation>")
    a(f'    <buttons names="{g["buttons"][0]}" default="{g["buttons"][1]}"/>')
    a("")
    a('    <switches default="FF,FF" base="16">')
    for bits, name, ids in g["dips"]:
        a(f'        <dip bits="{bits}" name="{name}" ids="{ids}"/>')
    a("    </switches>")
    a("")
    a(f'    <rom index="1"><part>{g["mod"]:02X}</part></rom>')
    a(f'    <rom index="0" zip="{game}.zip" md5="None">')
    for name, soff, length, src, roff, kind in stream_of(game):
        a(f"        <!-- {soff:06X} {name} -->")
        for line in mra_segments(game, src, roff, length, kind):
            a("        " + line)
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


MRA_FILE = {"nost": "Nostradamus.mra", "mcatadv": "Magical Cat Adventure.mra"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--game", default="nost", choices=sorted(GAMES))
    ap.add_argument("--zip", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--mra", default=None)
    a = ap.parse_args()
    game = a.game
    mra = a.mra or os.path.join(ROOT, "mra", MRA_FILE[game])
    if a.cmd == "mra":
        path = a.out or mra
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", newline="\n").write(make_mra(game))
        print("wrote", path)
        return 0
    data = load_zip(game, a.zip or os.path.join(ROMDIR, f"{game}.zip"))
    out = a.out or os.path.join(ROOT, "local", *([] if game == "nost" else [game]))
    os.makedirs(out, exist_ok=True)
    if a.cmd == "verify":
        return 0 if verify(game, data) else 1
    if not verify(game, data):
        return 1
    regs = build_regions(game, data)
    if a.cmd == "regions":
        d = os.path.join(out, "regions")
        os.makedirs(d, exist_ok=True)
        for n, r in regs.items():
            open(os.path.join(d, n + ".bin"), "wb").write(r)
        print("regions written to", d)
    elif a.cmd == "stream":
        s = build_stream(game, regs)
        open(os.path.join(out, f"{game}.rom"), "wb").write(s)
        print(f"stream {len(s):#x} bytes crc {zlib.crc32(s) & 0xffffffff:08x}")
    elif a.cmd == "images":
        d = os.path.join(out, "sim")
        os.makedirs(d, exist_ok=True)
        mem = build_sdram(game, regs)
        open(os.path.join(d, "sdram_le.bin"), "wb").write(mem)
        be = bytearray(len(mem))                    # 16-bit words big-endian (SDRAM chip model)
        be[0::2] = mem[1::2]
        be[1::2] = mem[0::2]
        open(os.path.join(d, "sdram_be.bin"), "wb").write(be)
        mc = regs["maincpu"]
        write_hex16(os.path.join(d, "maincpu.hex"), [(mc[2 * i] << 8) | mc[2 * i + 1] for i in range(len(mc) // 2)])
        write_hex8(os.path.join(d, "soundcpu.hex"), stream_chunk(game, regs, "soundcpu", 0, 0x40000))
        write_hex8(os.path.join(d, "adpcma.hex"), stream_chunk(game, regs, "adpcma", 0, 0x100000))
        z = stream_chunk(game, regs, "soundcpu", 0, 0x8000)   # nost_sound block-RAM copy of 0000-7FFF
        write_hex8(os.path.join(d, "zfix_lo.hex"), z[0::2])
        write_hex8(os.path.join(d, "zfix_hi.hex"), z[1::2])
        print("simulation images written to", d)
    elif a.cmd == "mracheck":
        got = interpret_mra(mra, data)
        want = build_stream(game, regs)
        s0 = got.get(0, b"")
        if s0 != want:
            n = min(len(s0), len(want))
            first = next((i for i in range(n) if s0[i] != want[i]), n)
            print(f"FAIL mracheck: len {len(s0):#x} vs {len(want):#x}, first difference at {first:#x}")
            return 1
        if got.get(1) != bytes([GAMES[game]["mod"]]):
            print(f"FAIL mracheck: index 1 = {got.get(1)!r}, expected {GAMES[game]['mod']:02x}")
            return 1
        print(f"PASS mracheck {game}: MRA stream == layout stream ({len(s0):#x} bytes, crc "
              f"{zlib.crc32(s0) & 0xffffffff:08x}), game byte {GAMES[game]['mod']:02x}")
    else:
        ap.error("unknown command")
    return 0


if __name__ == "__main__":
    sys.exit(main())
