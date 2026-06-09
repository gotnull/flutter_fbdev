#!/usr/bin/env bash
# build_embedder.sh - cross-compile the flutter_fbdev framebuffer embedder for an
# ARM64 Linux handheld and drop the binary INTO a flutter-pi-style asset bundle.
#
# Prefers `zig cc` (one self-contained cross-compiler - no VM/daemon, ~1s; install
# with `brew install zig` / your package manager). Falls back to a Docker arm64
# gcc container if zig isn't present.
#
# Usage:
#   native/build_embedder.sh <bundle-dir>
#
# <bundle-dir> is the flutter-pi asset bundle (built with `flutterpi_tool build
# --arch arm64 --cpu pi3 --release`) - it must already contain libflutter_engine.so.
# The embedder is written to <bundle-dir>/flutter_fbdev.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

BUNDLE="${1:-}"
[ -n "$BUNDLE" ] || { echo "usage: $0 <bundle-dir>" >&2; exit 2; }
[ -f "$BUNDLE/libflutter_engine.so" ] || {
  echo "no libflutter_engine.so in '$BUNDLE' - build the flutter-pi bundle first:" >&2
  echo "  flutterpi_tool build --arch arm64 --cpu pi3 --release" >&2
  exit 1
}

SRC="$HERE/flutter_fbdev_embedder.c"
OUT="$BUNDLE/flutter_fbdev"

if command -v zig >/dev/null 2>&1; then
  echo "› cross-compiling flutter_fbdev with zig (aarch64 Linux) …"
  zig cc -target aarch64-linux-gnu.2.31 -O2 -s -std=c11 -o "$OUT" "$SRC" \
    -I"$HERE" -L"$BUNDLE" -lflutter_engine -Wl,-rpath,'$ORIGIN' \
    -lpthread -lm -ldl
else
  echo "› zig not found (brew install zig) - using Docker arm64 gcc …"
  docker run --rm --platform linux/arm64 -v "$HERE":/h -v "$BUNDLE":/b -w /h gcc:13 \
    gcc -O2 -s -std=c11 -Wall -o /b/flutter_fbdev flutter_fbdev_embedder.c \
    -I/h -L/b -lflutter_engine -Wl,-rpath,'$ORIGIN' -lpthread -lm -ldl
fi

echo "✓ built $OUT"
file "$OUT" 2>/dev/null || true
