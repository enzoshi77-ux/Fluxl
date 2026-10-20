#!/usr/bin/env python3
"""Replace the NullsBotFill dylib inside an already-injected IPA.

Use this when the IPA already has the LC_LOAD_DYLIB command and a
Frameworks/NullsBotFill.dylib entry (for example a previous NullsBotFill
packaging release). Rewriting just that entry avoids a duplicate zip member
and leaves the main binary's load command untouched.

Usage:
  replace_ipa_dylib.py <input.ipa> <dylib> <output.ipa>
"""
import hashlib
import os
import shutil
import sys
import zipfile

ENTRY = "Payload/NB.app/Frameworks/NullsBotFill.dylib"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src, dylib, dst = sys.argv[1:]
    if os.path.abspath(src) == os.path.abspath(dst):
        print("error: output must differ from input", file=sys.stderr)
        return 2

    with zipfile.ZipFile(src) as zin:
        matches = [i for i in zin.infolist() if i.filename == ENTRY]
        if len(matches) != 1:
            print(f"error: expected one {ENTRY}, found {len(matches)}",
                  file=sys.stderr)
            return 1
        old = matches[0]

        tmp = dst + ".tmp"
        with zipfile.ZipFile(tmp, "w", allowZip64=True) as zout:
            for info in zin.infolist():
                if info.filename == ENTRY:
                    continue
                with zin.open(info) as r, zout.open(info, "w") as w:
                    shutil.copyfileobj(r, w, 1024 * 1024)
            new = zipfile.ZipInfo(ENTRY, date_time=old.date_time)
            new.compress_type = old.compress_type
            new.external_attr = old.external_attr
            new.create_system = old.create_system
            with open(dylib, "rb") as r, zout.open(new, "w") as w:
                shutil.copyfileobj(r, w, 1024 * 1024)
    os.replace(tmp, dst)

    with zipfile.ZipFile(dst) as z:
        entries = [i for i in z.infolist() if i.filename == ENTRY]
        if len(entries) != 1:
            print(f"error: output has {len(entries)} dylib entries",
                  file=sys.stderr)
            return 1
        data = z.read(ENTRY)
    want = sha256_file(dylib)
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        print(f"error: dylib hash mismatch {got} != {want}", file=sys.stderr)
        return 1
    print(f"[verify] one {ENTRY}")
    print(f"[verify] dylib sha256 {got}")
    print(f"[verify] {len(z.namelist())} entries, "
          f"{os.path.getsize(dst)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
