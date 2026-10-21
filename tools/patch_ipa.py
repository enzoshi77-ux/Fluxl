#!/usr/bin/env python3
"""Inject a dylib load command into an arm64 iOS Mach-O and ad-hoc sign it.

This is the packaging step only: it makes the app load `NullsBotFill.dylib`
from its own Frameworks folder, so LiveContainer's tweak loader is out of the
picture. Signing here is a placeholder signature - re-sign the finished IPA
with whatever tool signed LiveContainer before installing.

Usage:
  patch_ipa.py <input.ipa> <dylib> <output.ipa>
  patch_ipa.py --binary <macho> <dylib> <output.dylib-path-check>   (debug)
"""
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
CSSLOT_ENTITLEMENTS = 5
CS_ADHOC = 0x2
CS_EXECSEG_MAIN_BINARY = 0x1
PAGE = 16384
HASH_SIZE = 32


def align(value, boundary):
    return (value + boundary - 1) & ~(boundary - 1)


def load_commands(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    cmds = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        cmds.append((cmd, off, size))
        off += size
    return cmds


def sections(data):
    out = []
    for cmd, off, _ in load_commands(data):
        if cmd != LC_SEGMENT_64:
            continue
        segname = data[off + 8:off + 24].rstrip(b"\0").decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        sect = off + 72
        for _ in range(nsects):
            name = data[sect:sect + 16].rstrip(b"\0").decode()
            addr, size = struct.unpack_from("<QQ", data, sect + 32)
            soff = struct.unpack_from("<I", data, sect + 48)[0]
            out.append(dict(seg=segname, name=name, addr=addr, size=size,
                            offset=soff, vmaddr=vmaddr, fileoff=fileoff,
                            segsize=filesize))
            sect += 80
    return out


def signature_blobs(data):
    """Return {slot_type: bytes} from the existing embedded signature."""
    blobs = {}
    for cmd, off, _ in load_commands(data):
        if cmd != LC_CODE_SIGNATURE:
            continue
        dataoff, datasize = struct.unpack_from("<II", data, off + 8)
        blob = data[dataoff:dataoff + datasize]
        if len(blob) < 12:
            continue
        magic, length, count = struct.unpack_from(">III", blob, 0)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            continue
        for i in range(count):
            slot, slot_off = struct.unpack_from(">II", blob, 12 + i * 8)
            size = struct.unpack_from(">I", blob, slot_off + 4)[0]
            blobs[slot] = blob[slot_off:slot_off + size]
    return blobs


def inject(binary, install_name):
    """Insert LC_LOAD_DYLIB using header padding. Returns modified bytes."""
    data = bytearray(binary)
    magic, cpu, sub, filetype, ncmds, sizeofcmds, flags, _ = \
        struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"not a thin 64-bit Mach-O (magic 0x{magic:08x})")

    name = install_name.encode() + b"\0"
    cmdsize = align(24 + len(name), 8)

    header_end = 32 + sizeofcmds
    # Lowest file offset of any section payload: the load commands must stop
    # before it.
    offsets = [s["offset"] for s in sections(data) if s["offset"] > 0 and s["size"] > 0]
    first_payload = min(offsets) if offsets else 0
    if first_payload and header_end + cmdsize > first_payload:
        raise SystemExit(f"no header padding: need {cmdsize} bytes, "
                         f"have {first_payload - header_end}")

    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    cmd += name
    cmd += b"\0" * (cmdsize - len(cmd))

    data[header_end:header_end + cmdsize] = cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)
    return bytes(data)

def build_codedirectory(identifier, code_limit, pages, entitlements, exec_limit):
    ident = identifier.encode() + b"\0"
    n_special = 5 if entitlements else 0
    hash_off = 88 + len(ident) + n_special * HASH_SIZE

    version = 0x20400
    length = hash_off + len(pages) * HASH_SIZE
    flags = CS_ADHOC
    exec_flags = CS_EXECSEG_MAIN_BINARY if exec_limit else 0

    header = struct.pack(
        ">IIIIIIIIIBBBBIIIIQQQQ",
        0xFADE0C02, length, version, flags, hash_off, 88,
        n_special, len(pages), code_limit,
        HASH_SIZE, 2, 0, PAGE.bit_length() - 1,  # hashSize, sha256, platform, pageShift
        0, 0, 0, 0,                       # spare2, scatterOffset, teamOffset, spare3
        0,                                # codeLimit64 (0 = use codeLimit)
        0, exec_limit, exec_flags,        # execSegBase, execSegLimit, execSegFlags
    )
    assert len(header) == 88, len(header)

    blob = bytearray(header)
    blob += ident
    start = 88 + len(ident)
    blob += b"\0" * (n_special * HASH_SIZE)
    if entitlements:
        import hashlib
        blob[start:start + HASH_SIZE] = hashlib.sha256(entitlements).digest()
    for digest in pages:
        blob += digest
    return bytes(blob)


def sign(binary, identifier, entitlements):
    """Truncate the existing signature, append a fresh ad-hoc one.

    Two passes: the signature length is deterministic, so the header is made
    final (LC_CODE_SIGNATURE, __LINKEDIT sizes) before any page is hashed.
    """
    import hashlib

    data = bytearray(binary)
    sig_cmd = None
    for cmd, off, _ in load_commands(data):
        if cmd == LC_CODE_SIGNATURE:
            sig_cmd = (off, struct.unpack_from("<II", data, off + 8)[0])
    if not sig_cmd:
        raise SystemExit("binary has no LC_CODE_SIGNATURE; cannot sign in place")
    cmd_off, code_limit = sig_cmd

    data = data[:code_limit]
    filetype = struct.unpack_from("<I", data, 12)[0]
    text = next(s for s in sections(data) if s["seg"] == "__TEXT")
    exec_limit = text["segsize"] if filetype == 0x2 else 0
    n_code = (code_limit + PAGE - 1) // PAGE

    blank = [b"\0" * HASH_SIZE] * n_code
    sig_len = len(build_superblob(
        build_codedirectory(identifier, code_limit, blank, entitlements, exec_limit),
        entitlements))

    struct.pack_into("<II", data, cmd_off + 8, code_limit, sig_len)

    linkedit = None
    for cmd, off, _ in load_commands(data):
        if cmd == LC_SEGMENT_64 and data[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit = (off, struct.unpack_from("<Q", data, off + 40)[0])
    if not linkedit:
        raise SystemExit("no __LINKEDIT segment")
    off, fileoff = linkedit
    new_size = code_limit + sig_len - fileoff
    struct.pack_into("<Q", data, off + 32, align(new_size, 0x4000))  # vmsize
    struct.pack_into("<Q", data, off + 48, new_size)                 # filesize

    pages = [hashlib.sha256(bytes(data[s:min(s + PAGE, code_limit)])).digest()
             for s in range(0, code_limit, PAGE)]
    cd = build_codedirectory(identifier, code_limit, pages, entitlements, exec_limit)
    superblob = build_superblob(cd, entitlements)
    assert len(superblob) == sig_len, (len(superblob), sig_len)

    data += superblob
    return bytes(data)


def build_superblob(cd, entitlements):
    entries = [(CSSLOT_CODEDIRECTORY, cd)]
    if entitlements:
        entries.append((CSSLOT_ENTITLEMENTS, entitlements))

    offset = align(12 + 8 * len(entries), 8)
    body = bytearray()
    placed = []
    for slot, blob in entries:
        placed.append((slot, offset + len(body)))
        body += blob
        body += b"\0" * (align(len(body), 8) - len(body))

    out = bytearray(struct.pack(">III", CSMAGIC_EMBEDDED_SIGNATURE,
                                offset + len(body), len(entries)))
    for slot, pos in placed:
        out += struct.pack(">II", slot, pos)
    out += b"\0" * (offset - len(out))
    out += body
    return bytes(out)


def patch_app(binary, identifier):
    patched = inject(binary, "@rpath/NullsBotFill.dylib")
    entitlements = signature_blobs(binary).get(CSSLOT_ENTITLEMENTS)
    return sign(patched, identifier, entitlements)


def find_app(zin):
    for name in zin.namelist():
        if name.startswith("Payload/") and name.endswith(".app/") and name.count("/") == 2:
            return name
    raise SystemExit("no Payload/*.app in the archive")


def patch_ipa(src, dylib_path, dst):
    dylib_bytes = open(dylib_path, "rb").read()
    with zipfile.ZipFile(src) as zin:
        app = find_app(zin)
        info = plistlib.loads(zin.read(app + "Info.plist"))
        exe = info["CFBundleExecutable"]
        ident = info.get("CFBundleIdentifier", exe)
        exe_path = app + exe

        binary = zin.read(exe_path)
        patched = patch_app(binary, ident)
        print(f"[patch] {exe}: {len(binary)} -> {len(patched)} bytes")

        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
            for entry in zin.infolist():
                payload = patched if entry.filename == exe_path else zin.read(entry.filename)
                zout.writestr(entry, payload)

            zi = zipfile.ZipInfo(app + "Frameworks/NullsBotFill.dylib",
                                 date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = 0o100755 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zout.writestr(zi, dylib_bytes)
        print(f"[patch] injected {len(dylib_bytes)} byte dylib into {app}Frameworks")
    return dst


def verify(path):
    with zipfile.ZipFile(path) as zin:
        app = find_app(zin)
        info = plistlib.loads(zin.read(app + "Info.plist"))
        data = zin.read(app + info["CFBundleExecutable"])
        names = zin.namelist()

    libs = []
    for cmd, off, _ in load_commands(data):
        if cmd == LC_LOAD_DYLIB:
            noff = struct.unpack_from("<I", data, off + 8)[0]
            libs.append(data[off + noff:].split(b"\0")[0].decode())
    assert "@rpath/NullsBotFill.dylib" in libs, "load command missing"
    assert app + "Frameworks/NullsBotFill.dylib" in names, "dylib missing from bundle"
    print(f"[verify] load command present, {len(libs)} dylibs total")
    print(f"[verify] {len(names)} entries, dylib in Frameworks")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    src, dylib, dst = sys.argv[1:4]
    if not os.path.exists(src):
        raise SystemExit(f"missing {src}")
    patch_ipa(src, dylib, dst)
    verify(dst)
    print(f"[done] {dst}  ({os.path.getsize(dst) / 1e9:.2f} GB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

