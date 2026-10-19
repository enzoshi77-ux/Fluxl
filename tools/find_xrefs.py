#!/usr/bin/env python3
"""Find ADRP+ADD references to a string in an arm64 Mach-O, then map each hit
to its enclosing function via LC_FUNCTION_STARTS.

Usage: find_xrefs.py <macho> <needle> [--limit N]
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26
S_ZEROFILL = 0x1

ADRP_MASK, ADRP_OP = 0x9F000000, 0x90000000
ADD_MASK, ADD_OP = 0xFF800000, 0x91000000


def parse(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, segs, funcs = 32, [], None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sect = off + 72
            for _ in range(nsects):
                sname = data[sect:sect + 16].rstrip(b"\0").decode()
                addr, size = struct.unpack_from("<QQ", data, sect + 32)
                soff = struct.unpack_from("<I", data, sect + 48)[0]
                flags = struct.unpack_from("<I", data, sect + 64)[0]
                segs.append((name, sname, vmaddr, fileoff, addr, size, soff, flags))
                sect += 80
        elif cmd == LC_FUNCTION_STARTS:
            funcs = struct.unpack_from("<II", data, off + 8)
        off += cmdsize
    return segs, funcs


def uleb(data, pos):
    result = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def function_starts(data, funcs, text_vm):
    if not funcs:
        return []
    dataoff, size = funcs
    blob = data[dataoff:dataoff + size]
    starts, pos, addr = [], 0, text_vm
    while pos < len(blob) and blob[pos]:
        delta, pos = uleb(blob, pos)
        addr += delta
        starts.append(addr)
    return starts


def main():
    path, needle = sys.argv[1], sys.argv[2].encode()
    limit = 20
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    data = open(path, "rb").read()
    segs, funcs = parse(data)

    text = next(s for s in segs if s[1] == "__text")
    cstring = next(s for s in segs if s[1] == "__cstring")

    blob = data[cstring[6]:cstring[6] + cstring[5]]
    pos = blob.find(needle)
    if pos < 0:
        print(f"needle {needle!r} not found in __cstring")
        return 1
    target = cstring[4] + pos
    print(f"string 0x{target:x}  {needle.decode()}")

    starts = function_starts(data, funcs, text[4])
    starts_sorted = sorted(starts)

    def enclosing(addr):
        lo, hi, best = 0, len(starts_sorted) - 1, 0
        while lo <= hi:
            mid = (lo + hi) // 2
            if starts_sorted[mid] <= addr:
                best = starts_sorted[mid]
                lo = mid + 1
            else:
                hi = mid - 1
        return best

    tstart, tsize = text[6], text[5]
    base = text[4]
    hits = []
    for off in range(tstart, tstart + tsize, 4):
        insn = struct.unpack_from("<I", data, off)[0]
        if insn & ADRP_MASK != ADRP_OP:
            continue
        rd = insn & 0x1F
        immlo = (insn >> 29) & 3
        immhi = (insn >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = base + (off - tstart)
        page = (pc & ~0xFFF) + (imm << 12)

        for k in range(1, 5):
            noff = off + k * 4
            if noff >= tstart + tsize:
                break
            ninsn = struct.unpack_from("<I", data, noff)[0]
            if ninsn & ADD_MASK != ADD_OP:
                continue
            if ninsn & 0x1F != rd:
                continue
            if (ninsn >> 22) & 3:
                continue
            imm12 = (ninsn >> 10) & 0xFFF
            if page + imm12 == target:
                hits.append(base + (off - tstart))
    print(f"xrefs   {len(hits)}")
    for hit in hits[:limit]:
        fn = enclosing(hit)
        print(f"  0x{hit:x}  in function 0x{fn:x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
