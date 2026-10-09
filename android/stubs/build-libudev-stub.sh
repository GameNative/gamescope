#!/usr/bin/env bash
# Build + install the libudev stub into the termux prefix.
# Usage: ./build-libudev-stub.sh [prefix]   (default: ~/termuxfs/aarch64 prefix)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="${1:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
TOOLCHAIN="$HOME/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN/aarch64-linux-android28-clang"

mkdir -p "$DEPS/lib" "$DEPS/include" "$DEPS/lib/pkgconfig"

"$CC" -O2 -fPIC -shared -I"$SCRIPT_DIR/include" \
    -o "$DEPS/lib/libudev.so" "$SCRIPT_DIR/libudev.c" \
    -Wl,-soname,libudev.so

cp "$SCRIPT_DIR/include/libudev.h" "$DEPS/include/libudev.h"

cat > "$DEPS/lib/pkgconfig/libudev.pc" <<EOF
prefix=$DEPS
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libudev
Description: udev stub (Android) - empty discovery
Version: 249-stub
Libs: -L\${libdir} -ludev
Cflags: -I\${includedir}
EOF

echo "libudev stub installed to $DEPS"
