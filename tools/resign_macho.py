#!/usr/bin/env python3
"""Re-sign an existing arm64 iOS Mach-O with 16 KB code pages.

Keeps the current identifier and entitlements. Use this on a main binary that
was previously signed by ld64.lld/ldid with 4 KB slots.

Usage: resign_macho.py <macho> [output]
"""
import struct
import sys

import patch_ipa


def existing_identifier(binary):
    cd = patch_ipa.signature_blobs(binary).get(patch_ipa.CSSLOT_CODEDIRECTORY)
    if not cd:
        return "NullsBrawl"
    ident_off = struct.unpack_from(">I", cd, 20)[0]
    end = cd.index(b"\0", ident_off)
    return cd[ident_off:end].decode("utf-8", "replace")


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) == 3 else src
    data = open(src, "rb").read()
    ident = existing_identifier(data)
    entitlements = patch_ipa.signature_blobs(data).get(
        patch_ipa.CSSLOT_ENTITLEMENTS)
    signed = patch_ipa.sign(data, ident, entitlements)
    with open(dst, "wb") as fh:
        fh.write(signed)
    print(f"[resign] {dst}: {len(data)} -> {len(signed)} bytes, "
          f"page {patch_ipa.PAGE}, id {ident!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
