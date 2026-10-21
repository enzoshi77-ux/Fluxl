#!/usr/bin/env python3
"""Re-sign an arm64 iOS dylib with 16 KB code pages.

ld64.lld's -adhoc_codesign writes 4 KB code slots (pageShift 12), but iOS
arm64 uses 16 KB pages. AMFI rejects the 4 KB image before the dylib's
constructor runs, which looks like an immediate app crash. This rewrites the
embedded signature with 16 KB slots.

Linkers such as `zig cc` also emit no LC_CODE_SIGNATURE at all. When that
command is missing it is added in the Mach-O header padding first, so those
builds can be signed too.

Usage: sign_dylib.py <dylib>
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patch_ipa  # noqa: E402


def add_signature_command(data):
    """Add LC_CODE_SIGNATURE if the linker did not emit one."""
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
        raise SystemExit("no Mach-O header padding for LC_CODE_SIGNATURE; "
                         "link with -headerpad")

    out = bytearray(data)
    struct.pack_into("<IIII", out, header_end, patch_ipa.LC_CODE_SIGNATURE,
                     cmdsize, len(out), 0)
    struct.pack_into("<I", out, 16, ncmds + 1)
    struct.pack_into("<I", out, 20, sizeofcmds + cmdsize)
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as fh:
        data = fh.read()

    data = add_signature_command(data)
    entitlements = patch_ipa.signature_blobs(data).get(
        patch_ipa.CSSLOT_ENTITLEMENTS)
    signed = patch_ipa.sign(data, "NullsBotFill.dylib", entitlements)
    with open(path, "wb") as fh:
        fh.write(signed)
    print(f"[sign] {path}: {len(data)} -> {len(signed)} bytes, "
          f"page {patch_ipa.PAGE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
