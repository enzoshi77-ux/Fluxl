#!/usr/bin/env python3
"""Replace one or more files inside an IPA without duplicating zip members.

Usage:
  repack_ipa.py input.ipa output.ipa --replace ENTRY=FILE [--replace ...]

Example:
  repack_ipa.py in.ipa out.ipa \
      --replace "Payload/NB.app/Nulls Brawl=new_main" \
      --replace "Payload/NB.app/Frameworks/NullsBotFill.dylib=new.dylib"
"""
import argparse
import hashlib
import os
import shutil
import sys
import zipfile


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--replace", action="append", default=[],
                    metavar="ENTRY=FILE")
    args = ap.parse_args()

    replacements = {}
    for item in args.replace:
        if "=" not in item:
            print(f"error: bad --replace {item!r}", file=sys.stderr)
            return 2
        entry, path = item.split("=", 1)
        replacements[entry] = path

    with zipfile.ZipFile(args.input) as zin:
        names = set(zin.namelist())
        for entry in replacements:
            if entry not in names:
                print(f"error: {entry} not in input", file=sys.stderr)
                return 1
        tmp = args.output + ".tmp"
        with zipfile.ZipFile(tmp, "w", allowZip64=True) as zout:
            for info in zin.infolist():
                if info.filename in replacements:
                    continue
                with zin.open(info) as r, zout.open(info, "w") as w:
                    shutil.copyfileobj(r, w, 1024 * 1024)
            for entry, path in replacements.items():
                old = zin.getinfo(entry)
                info = zipfile.ZipInfo(entry, date_time=old.date_time)
                info.compress_type = old.compress_type
                info.external_attr = old.external_attr
                info.create_system = old.create_system
                with open(path, "rb") as r, zout.open(info, "w") as w:
                    shutil.copyfileobj(r, w, 1024 * 1024)
    os.replace(tmp, args.output)

    with zipfile.ZipFile(args.output) as z:
        for entry, path in replacements.items():
            matches = [i for i in z.infolist() if i.filename == entry]
            if len(matches) != 1:
                print(f"error: {entry} has {len(matches)} entries",
                      file=sys.stderr)
                return 1
            got = hashlib.sha256(z.read(entry)).hexdigest()
            want = sha256(path)
            if got != want:
                print(f"error: {entry} hash mismatch", file=sys.stderr)
                return 1
            print(f"[verify] {entry} {got}")
    print(f"[done] {args.output} ({os.path.getsize(args.output)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
