#!/usr/bin/env bash
# Build NullsBotFill.dylib for arm64 iOS.
#
# Linux host: clang + ld64.lld, no Apple SDK. The headers in sdk-stubs/ stand
# in for Foundation/UIKit; every symbol they declare resolves against the host
# app at load time.
# macOS host: same path, or the real iPhoneOS SDK when xcrun is present.
#
# Overrides: CLANG=... LD64LLD=... SDK=...

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/NullsBotFill.m"
OBJ="$ROOT/build/NullsBotFill.o"
OUT="$ROOT/dist/NullsBotFill.dylib"
ARCH="arm64"
MIN_IOS="14.0"

mkdir -p "$ROOT/build" "$ROOT/dist"

python3 "$ROOT/tools/verify_plist.py" "$ROOT/NullsBotFill.plist"

find_tool() {
    local name="$1" override="${2:-}" candidate
    if [ -n "$override" ] && [ -x "$override" ]; then echo "$override"; return; fi
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
    for candidate in "$HOME"/tools/root/usr/lib/llvm-*/bin/"$name"; do
        [ -x "$candidate" ] && { echo "$candidate"; return; }
    done
    echo ""
}

CLANG_BIN="$(find_tool clang "${CLANG:-}")"
[ -n "$CLANG_BIN" ] || { echo "error: clang not found (set CLANG=)" >&2; exit 1; }

# Debian clang loads libLLVM/libclang-cpp from its own prefix.
CLANG_PREFIX="$(dirname "$(dirname "$(readlink -f "$CLANG_BIN")")")"
export LD_LIBRARY_PATH="${CLANG_PREFIX}/lib:$(dirname "$CLANG_PREFIX")/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

RESOURCE="$("$CLANG_BIN" -print-resource-dir)"
SDK_PATH="${SDK:-}"
if [ -z "$SDK_PATH" ] && command -v xcrun >/dev/null 2>&1; then
    SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
fi

CFLAGS=(-target "${ARCH}-apple-ios${MIN_IOS}"
        -fobjc-arc -fblocks
        -O2 -Wall -Wextra -Wno-unused-parameter
        -c "$SRC" -o "$OBJ")

echo "[build] clang: $CLANG_BIN"
if [ -n "$SDK_PATH" ]; then
    echo "[build] sdk:   $SDK_PATH"
    "$CLANG_BIN" -isysroot "$SDK_PATH" "${CFLAGS[@]}"
else
    echo "[build] sdk:   sdk-stubs (no Apple SDK)"
    "$CLANG_BIN" -nostdinc -isystem "$RESOURCE/include" -I "$ROOT/sdk-stubs" "${CFLAGS[@]}"
fi

LD64="$(find_tool ld64.lld "${LD64LLD:-}")"
if [ -n "$LD64" ]; then
    echo "[build] ld64:  $LD64 (ad-hoc codesign)"
    "$LD64" -arch "$ARCH" \
            -platform_version ios "$MIN_IOS" "$MIN_IOS" \
            -dylib -install_name @rpath/NullsBotFill.dylib \
            -adhoc_codesign -undefined dynamic_lookup \
            -o "$OUT" "$OBJ"
else
    command -v xcrun >/dev/null 2>&1 || {
        echo "error: no ld64.lld and no xcrun (set LD64LLD=)" >&2; exit 1; }
    echo "[build] link:  xcrun clang -dynamiclib"
    xcrun --sdk iphoneos clang -isysroot "$SDK_PATH" -arch "$ARCH" \
          -mios-version-min="$MIN_IOS" -dynamiclib \
          -install_name @rpath/NullsBotFill.dylib \
          -Wl,-adhoc_codesign -undefined dynamic_lookup \
          -o "$OUT" "$OBJ"
    if command -v ldid >/dev/null 2>&1; then
        ldid -S "$OUT"
    else
        echo "[warn] ldid missing: if the dylib will not load, run 'ldid -S $OUT'" >&2
    fi
fi

python3 "$ROOT/tools/sign_dylib.py" "$OUT"
python3 "$ROOT/tools/verify_macho.py" "$OUT"
echo "[build] $OUT"
