#!/usr/bin/env bash
# Prepares the bionic prefix that android/build-gamescope.sh builds against.
#
# The Android gamescope build links against a Termux userland (cairo, pixman,
# lcms2, libdrm, xkbcommon, wayland, X11/xcb, EGL/GLES/GBM, Vulkan). Rather than
# cross-building that userland, this takes proton-wine's prebuilt tree and adds
# what it does not carry: wayland-protocols, libXres, libxkbfile, xcb-util-wm,
# luajit and hwdata.
#
# Usage:
#   android/ci/termux-prefix.sh [--root DIR] [--work DIR] [--tar FILE]
# Prints the prefix path on success (last line).

set -euo pipefail

NDK_VERSION="${NDK_VERSION:-27.3.13750724}"
NDK="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/$NDK_VERSION}}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
TERMUXFS_URL="https://github.com/GameNative/termux-on-gha/releases/download/build-20260218/termuxfs-aarch64.tar"
TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
WAYLAND_PROTOCOLS_VERSION="1.49"

# Same layout the workflow provisions (and proton-wine uses).
ROOT="$HOME/termuxfs/aarch64"
WORK="/tmp/ci-work"
TAR="$HOME/termuxfs-aarch64.tar"

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --tar) TAR="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PREFIX="$ROOT/data/data/com.termux/files/usr"
JOBS="$(nproc)"
mkdir -p "$WORK/src"

[ -x "$TOOLCHAIN/aarch64-linux-android28-clang" ] || { echo "NDK not found at $NDK" >&2; exit 1; }

log() { echo "=== $*"; }

# The tree names the on-device path in its .pc files. Point them at the
# extracted copy, and drop ${pc_sysrootdir} (pkgconf would prepend its own
# prefix to it, doubling the path).
normalize_pc() {
    find "$PREFIX/lib/pkgconfig" "$PREFIX/share/pkgconfig" -name '*.pc' -print0 |
        python3 -c '
import re, sys

prefix = sys.argv[1].rstrip("/")
dev = "/data/data/com.termux/files/usr"
root = prefix[: -len(dev)] if prefix.endswith(dev) else ""

for path in sys.stdin.read().split("\0"):
    if not path:
        continue
    text = open(path, encoding="utf-8", errors="surrogateescape").read()
    text = text.replace("${pc_sysrootdir}", "")
    if root:
        # collapse /root/root/...: re-running this script must not stack roots
        text = re.sub(re.escape(root) + "(?:" + re.escape(root) + ")+", root, text)
        # rewrite the on-device path, but leave an already-rewritten one alone
        text = re.sub("(?<!" + re.escape(root) + ")" + re.escape(dev), prefix, text)
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)
' "$PREFIX"
}

# --- 1. the Termux userland -------------------------------------------------
if [ ! -d "$PREFIX/lib/pkgconfig" ]; then
    log "termuxfs"
    [ -f "$TAR" ] || curl -fL --retry 3 -o "$TAR" "$TERMUXFS_URL"
    mkdir -p "$ROOT"
    tar -xf "$TAR" -C "$ROOT"
fi
normalize_pc

# --- 2. termux packages the tree does not carry -----------------------------
# termux_pkg <package> <file that proves it is installed, relative to PREFIX>
termux_pkg() {
    local name="$1" marker="$2"
    [ -e "$PREFIX/$marker" ] && return 0
    log "$name (termux package)"
    local index="$WORK/src/termux-Packages.gz"
    [ -f "$index" ] || curl -fL --retry 3 -o "$index" \
        "$TERMUX_REPO/dists/stable/main/binary-aarch64/Packages.gz"
    local path
    path="$(zcat "$index" | awk -v want="Package: $name" \
        '$0 == want { f = 1 } f && /^Filename: / && !seen { print $2; seen = 1 }')"
    [ -n "$path" ] || { echo "$name not in the termux index" >&2; exit 1; }
    local deb="$WORK/src/$name.deb" unpack="$WORK/src/$name-unpacked"
    [ -f "$deb" ] || curl -fL --retry 3 -o "$deb" "$TERMUX_REPO/$path"
    rm -rf "$unpack" && mkdir -p "$unpack"
    # a .deb is an ar archive; avoid depending on dpkg-deb being installed
    local member flag
    member="$(ar t "$deb" | grep '^data.tar')"
    case "$member" in
        *.xz) flag=-J ;; *.gz) flag=-z ;; *.zst) flag=--zstd ;; *) flag= ;;
    esac
    # shellcheck disable=SC2086
    ar p "$deb" "$member" | tar $flag -x -C "$unpack"
    cp -a "$unpack/data/data/com.termux/files/usr/." "$PREFIX/"
}

# gamescope's Lua configuration support
termux_pkg luajit lib/pkgconfig/luajit.pc
# EDID vendor names
termux_pkg hwdata share/hwdata/pnp.ids

# --- 3. wayland-protocols (protocol XML + its pkg-config file) --------------
if [ ! -f "$PREFIX/share/pkgconfig/wayland-protocols.pc" ]; then
    log "wayland-protocols-$WAYLAND_PROTOCOLS_VERSION"
    src="wayland-protocols-$WAYLAND_PROTOCOLS_VERSION"
    tar="$WORK/src/$src.tar.xz"
    [ -f "$tar" ] || curl -fL --retry 3 -o "$tar" \
        "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/$WAYLAND_PROTOCOLS_VERSION/downloads/$src.tar.xz"
    rm -rf "${WORK:?}/src/$src"
    tar -xf "$tar" -C "$WORK/src"
    # Native tools only (wayland-scanner): the prefix's pkg-config path would
    # hand meson the aarch64 scanner.
    ( cd "$WORK/src/$src" && env -u PKG_CONFIG_LIBDIR meson setup build \
          --prefix="$PREFIX" -Dtests=false >/dev/null &&
      env -u PKG_CONFIG_LIBDIR meson install -C build >/dev/null )
    sed -i "s#^prefix=.*#prefix=$PREFIX#" "$PREFIX/share/pkgconfig/wayland-protocols.pc"
fi

# --- 4. libraries the termux tree does not carry ---------------------------
# build_lib <name> <version> <pkg-config file to test> <tarball url>
build_lib() {
    local name="$1" version="$2" pc="$3" url="$4"
    [ -f "$PREFIX/lib/pkgconfig/$pc" ] && return 0
    log "$name-$version"
    local src="$name-$version" tar="$WORK/src/$(basename "$url")"
    [ -f "$tar" ] || curl -fL --retry 3 -o "$tar" "$url"
    rm -rf "${WORK:?}/src/$src"
    tar -xf "$tar" -C "$WORK/src"
    (
        cd "$WORK/src/$src"
        extra=()
        grep -q "enable-malloc0returnsnull" configure &&
            extra+=(--enable-malloc0returnsnull=no)
        PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" \
        CC="$TOOLCHAIN/aarch64-linux-android28-clang" \
        AR="$TOOLCHAIN/llvm-ar" STRIP="$TOOLCHAIN/llvm-strip" \
        ./configure --host=aarch64-linux-android --prefix="$PREFIX" \
            --disable-static "${extra[@]}" >/dev/null
        make -j "$JOBS" >/dev/null
        make install >/dev/null
    )
}

# libxcvt has no configure script; it is a meson project
build_lib_meson() {
    local name="$1" version="$2" pc="$3" url="$4"
    [ -f "$PREFIX/lib/pkgconfig/$pc" ] && return 0
    log "$name-$version"
    local src="$name-$version" tar="$WORK/src/$(basename "$url")"
    [ -f "$tar" ] || curl -fL --retry 3 -o "$tar" "$url"
    rm -rf "${WORK:?}/src/$src"
    tar -xf "$tar" -C "$WORK/src"
    cat > "$WORK/cross-$name.txt" <<CROSS
[binaries]
c = '$TOOLCHAIN/aarch64-linux-android28-clang'
cpp = '$TOOLCHAIN/aarch64-linux-android28-clang++'
ar = '$TOOLCHAIN/llvm-ar'
strip = '$TOOLCHAIN/llvm-strip'
pkgconfig = '$(command -v pkg-config)'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'

[properties]
pkg_config_libdir = ['$PREFIX/lib/pkgconfig', '$PREFIX/share/pkgconfig']
CROSS
    (
        cd "$WORK/src/$src"
        meson setup build --cross-file "$WORK/cross-$name.txt" \
            --prefix="$PREFIX" --buildtype=release >/dev/null
        meson install -C build >/dev/null
    )
}

build_lib libXres 1.2.2 xres.pc \
    https://xorg.freedesktop.org/releases/individual/lib/libXres-1.2.2.tar.gz
# xkbcomp is exec'd by Xwayland and links libxkbfile
build_lib libxkbfile 1.1.3 xkbfile.pc \
    https://xorg.freedesktop.org/releases/individual/lib/libxkbfile-1.1.3.tar.gz
# wlroots' xwayland support requires xcb-ewmh and xcb-icccm
build_lib xcb-util-wm 0.4.2 xcb-ewmh.pc \
    https://xcb.freedesktop.org/dist/xcb-util-wm-0.4.2.tar.gz
# Xwayland requires xfont2 and libxcvt at configure time
build_lib libfontenc 1.1.9 fontenc.pc \
    https://xorg.freedesktop.org/releases/individual/lib/libfontenc-1.1.9.tar.gz
# xtrans is header-only and ships in neither prefix; libXfont2 requires it
if [ ! -f "$PREFIX/include/X11/Xtrans/Xtrans.h" ]; then
    log "xtrans-1.6.0"
    tar="$WORK/src/xtrans-1.6.0.tar.xz"
    [ -f "$tar" ] || curl -fL --retry 3 -o "$tar" \
        "https://xorg.freedesktop.org/releases/individual/lib/xtrans-1.6.0.tar.xz"
    rm -rf "${WORK:?}/src/xtrans-1.6.0"
    tar -xf "$tar" -C "$WORK/src"
    mkdir -p "$PREFIX/include/X11/Xtrans" "$PREFIX/lib/pkgconfig"
    cp "$WORK/src/xtrans-1.6.0"/*.h "$WORK/src/xtrans-1.6.0"/*.c \
        "$PREFIX/include/X11/Xtrans/"
    sed -e "s|@prefix@|$PREFIX|;s|@exec_prefix@|\${prefix}|" \
        -e "s|@libdir@|\${exec_prefix}/lib|;s|@includedir@|\${prefix}/include|" \
        -e "s|@PACKAGE_VERSION@|1.6.0|;s|@fchown_define@||;s|@sticky_bit_define@||" \
        "$WORK/src/xtrans-1.6.0/xtrans.pc.in" > "$PREFIX/lib/pkgconfig/xtrans.pc"
fi
build_lib libXfont2 2.0.9 xfont2.pc \
    https://xorg.freedesktop.org/releases/individual/lib/libXfont2-2.0.9.tar.gz
build_lib_meson libxcvt 0.1.3 libxcvt.pc \
    https://xorg.freedesktop.org/releases/individual/lib/libxcvt-0.1.3.tar.xz

normalize_pc

echo "prefix: $PREFIX"
