#!/usr/bin/env python3
"""Ad-hoc sign an arm64 Mach-O dylib in place.

Linkers other than ld64.lld (for example `zig cc`) produce a structurally
complete dylib without LC_CODE_SIGNATURE. This adds that command in the header
padding and then appends a SHA-256 ad-hoc signature, reusing the signer in
patch_ipa.py.

Usage: sign_dylib.py dist/NullsBotFill.dylib [identifier]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patch_ipa  # noqa: E402


def add_signature_command(data):
    magic, _cpu, _sub, _filetype, ncmds, sizeofcmds, _flags, _ = \
        struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit("not a thin 64-bit Mach-O")

    for cmd, _off, _ in patch_ipa.load_commands(data):
        if cmd == patch_ipa.LC_CODE_SIGNATURE:
            return data

    cmdsize = 16
    header_end = 32 + sizeofcmds
    offsets = [s["offset"] for s in patch_ipa.sections(data)
               if s["offset"] > 0 and s["size"] > 0]
    first_payload = min(offsets) if offsets else 0
    if not first_payload or header_end + cmdsize > first_payload:
        raise SystemExit("no header padding for LC_CODE_SIGNATURE")

    out = bytearray(data)
    struct.pack_into("<IIII", out, header_end, patch_ipa.LC_CODE_SIGNATURE,
                     cmdsize, len(out), 0)
    struct.pack_into("<I", out, 16, ncmds + 1)
    struct.pack_into("<I", out, 20, sizeofcmds + cmdsize)
    return bytes(out)


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        return 2

    path = sys.argv[1]
    identifier = sys.argv[2] if len(sys.argv) == 3 else "NullsBotFill"

    with open(path, "rb") as handle:
        data = handle.read()

    data = add_signature_command(data)
    signed = patch_ipa.sign(data, identifier, None)

    with open(path, "wb") as handle:
        handle.write(signed)

    print(f"[sign] {path}: ad-hoc, {len(signed)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
