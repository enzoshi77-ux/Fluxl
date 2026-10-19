#!/usr/bin/env python3
"""Structural check for a signed arm64 Mach-O dylib.

Parses the load commands, walks the embedded code signature, and recomputes
every code-page hash. Exits non-zero on any mismatch.

Usage: verify_macho.py dist/NullsBotFill.dylib
"""
import hashlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_ARM64 = 0x0100000C
MH_DYLIB = 0x6
LC_CODE_SIGNATURE = 0x1D

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
HASH_SHA256 = 2


def die(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def parse_macho(data):
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = \
        struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        die(f"not a 64-bit Mach-O (magic 0x{magic:08x})")
    if cputype != CPU_ARM64:
        die(f"not arm64 (cputype 0x{cputype:08x})")
    if filetype != MH_DYLIB:
        die(f"not MH_DYLIB (filetype {filetype})")

    commands = []
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        commands.append((cmd, off, cmdsize))
        off += cmdsize
    return commands


def code_signature(commands, data):
    for cmd, off, _ in commands:
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            return dataoff, datasize
    return None


def verify_signature(data, dataoff, datasize):
    if dataoff + datasize > len(data):
        die("LC_CODE_SIGNATURE extends past end of file")

    blob = data[dataoff:dataoff + datasize]
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        die(f"bad superblob magic 0x{magic:08x}")
    if length != datasize:
        die(f"superblob length {length} != LC datasize {datasize}")

    cd_off = None
    for i in range(count):
        slot_type, slot_off = struct.unpack_from(">II", blob, 12 + i * 8)
        if slot_type == CSSLOT_CODEDIRECTORY:
            cd_off = slot_off
    if cd_off is None:
        die("no CodeDirectory in superblob")

    cd = blob[cd_off:]
    (magic, length, version, flags, hash_off, ident_off, n_special,
     n_code, code_limit) = struct.unpack_from(">9I", cd, 0)
    hash_size, hash_type, platform, page_shift = struct.unpack_from(">4B", cd, 36)

    if magic != CSMAGIC_CODEDIRECTORY:
        die(f"bad CodeDirectory magic 0x{magic:08x}")
    if hash_type != HASH_SHA256 or hash_size != 32:
        die(f"expected sha256 code slots, got hash_type={hash_type} size={hash_size}")
    if code_limit > dataoff:
        die(f"codeLimit {code_limit} overlaps the signature at {dataoff}")

    ident = cd[ident_off:cd.index(b"\0", ident_off)].decode("utf-8", "replace")
    page_size = 1 << page_shift

    pages = (code_limit + page_size - 1) // page_size
    if pages != n_code:
        die(f"page count {pages} != nCodeSlots {n_code}")

    hash_start = cd_off + hash_off
    for index in range(n_code):
        start = index * page_size
        end = min(start + page_size, code_limit)
        digest = hashlib.sha256(data[start:end]).digest()
        slot = blob[hash_start + index * hash_size:
                    hash_start + (index + 1) * hash_size]
        if digest != slot:
            die(f"code page {index} hash mismatch "
                f"(offset 0x{start:x}, len {end - start})")

    print(f"  signature : ad-hoc, {n_code} code slots, "
          f"{n_special} special slots, page {page_size}")
    print(f"  identifier: {ident}")
    print(f"  codeLimit : 0x{code_limit:x}  sig @ 0x{dataoff:x}  "
          f"flags 0x{flags:x}")
    return ident


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    path = sys.argv[1]
    with open(path, "rb") as handle:
        data = handle.read()

    commands = parse_macho(data)
    print(f"  file      : {path} ({len(data)} bytes, arm64 MH_DYLIB)")

    sig = code_signature(commands, data)
    if not sig:
        die("no LC_CODE_SIGNATURE — the kernel will refuse to map this dylib")

    verify_signature(data, *sig)
    print("  result    : OK")


if __name__ == "__main__":
    main()
