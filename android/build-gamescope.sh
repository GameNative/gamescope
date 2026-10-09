#!/usr/bin/env bash
# build-gamescope.sh — apply the GameNative Android patch train and cross-build
# gamescope for aarch64-linux-android (API 28) against the termux prefix.
#
# Modelled on the proton-wine build scripts: the gamescope tree stays
# upstream-clean; this script applies android/patches/** then builds.
#
# Usage:
#   android/build-gamescope.sh [--skip-patches] [--setup-only]
#
# Env overrides:
#   NDK        — NDK path           (default: $HOME/Android/Sdk/ndk/27.3.13750724)
#   TERMUXFS   — prefix root        (default: $HOME/termuxfs/aarch64/data/data/com.termux/files/usr)
#   BUILD_DIR  — meson build dir    (default: build-android)
set -euo pipefail

GS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NDK="${NDK:-$HOME/Android/Sdk/ndk/27.3.13750724}"
TERMUXFS="${TERMUXFS:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
BUILD_DIR="${BUILD_DIR:-build-android}"
SKIP_PATCHES=0
SETUP_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --skip-patches) SKIP_PATCHES=1 ;;
        --setup-only)   SETUP_ONLY=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ -d "$NDK" ]        || { echo "NDK not found at $NDK" >&2; exit 1; }
[ -d "$TERMUXFS" ]   || { echo "termux prefix not found at $TERMUXFS" >&2; exit 1; }

# --- 0. cross file --------------------------------------------------------
# android/cross/aarch64-linux-android.txt is generated from the committed
# .txt.in template and the NDK/TERMUXFS above, so no absolute path is stored in
# the tree. Regenerated on every run; meson reads it at every setup/reconfigure.
CROSS_IN="$GS_DIR/android/cross/aarch64-linux-android.txt.in"
CROSS_OUT="$GS_DIR/android/cross/aarch64-linux-android.txt"
sed -e "s|@NDK_BIN@|$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin|g" \
    -e "s|@TERMUXFS@|$TERMUXFS|g" \
    "$CROSS_IN" > "$CROSS_OUT"
if grep -q '@NDK_BIN@\|@TERMUXFS@' "$CROSS_OUT"; then
    echo "cross file still has unsubstituted placeholders: $CROSS_OUT" >&2
    exit 1
fi

# gamescope needs ALL submodules (incl. src/reshade, thirdparty/SPIRV-Headers):
#   subprojects/{wlroots,libliftoff,vkroots,libdisplay-info,openvr} src/reshade
#   thirdparty/SPIRV-Headers
if [ ! -d "$GS_DIR/src/reshade/source" ] || [ ! -d "$GS_DIR/subprojects/wlroots/include" ]; then
    echo "submodules missing — run: git -C \"$GS_DIR\" submodule update --init --recursive" >&2
    exit 1
fi

# --- 1. patch train -------------------------------------------------------
if [ "$SKIP_PATCHES" = 0 ]; then
    for p in "$GS_DIR"/android/patches/gamescope/*.patch; do
        if git -C "$GS_DIR" apply --check "$p" 2>/dev/null; then
            git -C "$GS_DIR" apply "$p"
            echo "applied $(basename "$p")"
        elif git -C "$GS_DIR" apply -R --check "$p" 2>/dev/null; then
            echo "already applied: $(basename "$p")"
        else
            echo "PATCH DOES NOT APPLY: $p" >&2
            exit 1
        fi
    done
    # wlroots submodule
    if [ -d "$GS_DIR/subprojects/wlroots/.git" ] || [ -f "$GS_DIR/subprojects/wlroots/.git" ]; then
        for p in "$GS_DIR"/android/patches/wlroots/*.patch; do
            if git -C "$GS_DIR/subprojects/wlroots" apply --check "$p" 2>/dev/null; then
                git -C "$GS_DIR/subprojects/wlroots" apply "$p"
                echo "applied wlroots/$(basename "$p")"
            elif git -C "$GS_DIR/subprojects/wlroots" apply -R --check "$p" 2>/dev/null; then
                echo "already applied: wlroots/$(basename "$p")"
            else
                echo "PATCH DOES NOT APPLY: $p" >&2
                exit 1
            fi
        done
    fi
fi

# --- 2. meson setup -------------------------------------------------------
# NOTE: PKG_CONFIG_LIBDIR must NOT leak into this environment from the shell —
# it would also override the *native* pkg-config search path, making meson pick
# the aarch64 wayland-scanner from the prefix ("cannot execute binary file").
# The cross file carries the correct pkg_config_libdir for cross lookups.
MESON_OPTIONS=(
    --cross-file android/cross/aarch64-linux-android.txt
    -Ddrm_backend=enabled
    -Dsdl2_backend=disabled
    -Denable_openvr_support=false
    -Denable_gamescope_wsi_layer=false
    -Denable_tests=false
    -Denable_zenity=false
    -Dpipewire=disabled
    -Dinput_emulation=disabled
    -Davif_screenshots=disabled
    -Drt_cap=disabled
    -Dwlroots:backends=
    -Dwlroots:session=disabled
)

cd "$GS_DIR"
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    # missing or incomplete setup (e.g. an earlier failed attempt left the dir)
    rm -rf "$BUILD_DIR"
    env -u PKG_CONFIG_LIBDIR meson setup "$BUILD_DIR" "${MESON_OPTIONS[@]}"
else
    echo "build dir '$BUILD_DIR' already configured — reusing (delete for a clean setup)"
fi

# --- 3. build -------------------------------------------------------------
if [ "$SETUP_ONLY" = 0 ]; then
    ninja -C "$BUILD_DIR"
    echo
    echo "=== artifact ==="
    file "$BUILD_DIR/src/gamescope"
fi
