#!/usr/bin/env bash
# Downloads the pinned upstream Mesa release, checks its sha256, extracts it
# and applies patches/ in filename order.
#
# Usage: android/mesa-glamor/fetch-mesa.sh <build root>
#   The tarball is kept in GN_MESA_TARBALL_DIR (default: the build root) so a
#   cache can hold it; the source tree is always extracted fresh.
# Prints the patched source directory (last line).

set -euo pipefail

MESA_VERSION="26.2.6"
MESA_SHA256="b9436b3e1a8be76fbd4823dc884f90596ab7c6ac5e1867a305e66ffccfb31a92"
MESA_URL="https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:?usage: $0 <build root>}"
TARBALL_DIR="${GN_MESA_TARBALL_DIR:-$ROOT}"
TARBALL="$TARBALL_DIR/mesa-$MESA_VERSION.tar.xz"
SRC="$ROOT/mesa-$MESA_VERSION"

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$ROOT" "$TARBALL_DIR"
if [ ! -f "$TARBALL" ] || [ "$(sha256 "$TARBALL")" != "$MESA_SHA256" ]; then
    curl -fL --retry 3 -o "$TARBALL.part" "$MESA_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
got="$(sha256 "$TARBALL")"
if [ "$got" != "$MESA_SHA256" ]; then
    echo "sha256 mismatch for $TARBALL: $got, expected $MESA_SHA256" >&2
    exit 1
fi

rm -rf "$SRC"
tar -xf "$TARBALL" -C "$ROOT"
for p in "$HERE"/patches/*.patch; do
    echo "applying ${p##*/}" >&2
    patch -d "$SRC" -p1 --forward --batch --no-backup-if-mismatch < "$p" >&2
done

echo "$SRC"
