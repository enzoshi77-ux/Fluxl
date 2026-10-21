#!/usr/bin/env python3
"""Re-sign an arm64 iOS dylib with 16 KB code pages.

ld64.lld's -adhoc_codesign writes 4 KB code slots (pageShift 12), but iOS
arm64 uses 16 KB pages. AMFI rejects the 4 KB image before the dylib's
constructor runs, which looks like an immediate app crash. This rewrites the
embedded signature with 16 KB slots.

Usage: sign_dylib.py <dylib>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patch_ipa  # noqa: E402


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as fh:
        data = fh.read()

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
