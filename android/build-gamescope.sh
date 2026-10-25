#!/usr/bin/env bash
# build-gamescope.sh — apply the GameNative Android patch train and cross-build
# gamescope for aarch64-linux-android (API 28) against the termux prefix.
#
# Modelled on the proton-wine build scripts: the gamescope tree stays
# upstream-clean; this script applies android/patches/** then builds.
#
# Usage:
#   android/build-gamescope.sh [--skip-patches] [--setup-only] [--clean] [--include-diagnostics]
#
# --include-diagnostics also applies android/patches/diagnostics/*.patch on top
# of the train: opt-in bring-up logging (A17 prepare-path, A23 present-path,
# A25 startup-present) that is not part of the shipping build. Off by default,
# so a normal build never carries it. Composes with the flags above.
#
# --clean restores the tree to what the patch train expects: tracked files
# reset, untracked meson state removed (patch-seeded headers, the wrap-redirect
# files meson writes), the patch stamp removed, the wrap overlays re-applied,
# the meson build dir dropped. android/patches is copied out before the reset
# and back after it, so a local patch experiment — edited or added files — is
# kept and re-applied. Ignored paths are otherwise left alone, so .idea/, the
# fetched subprojects and the meson package cache survive. The discarded diff
# is saved first. Composes with the flags above.
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
# Patch-train stamp: name + blob hash per applied patch (see step 1).
PATCH_STAMP="$GS_DIR/.gn-patches-applied"
SKIP_PATCHES=0
SETUP_ONLY=0
DO_CLEAN=0
INCLUDE_DIAGNOSTICS=0
for arg in "$@"; do
    case "$arg" in
        --skip-patches)        SKIP_PATCHES=1 ;;
        --setup-only)          SETUP_ONLY=1 ;;
        --clean)               DO_CLEAN=1 ;;
        --include-diagnostics) INCLUDE_DIAGNOSTICS=1 ;;
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

# --- 0.5 clean (only with --clean) -----------------------------------------
# The patch-seeded and fetched build state is untracked, so `git reset --hard`
# leaves it behind and the patch train then fails on a stale file (for example
# src/Utils/AtomicSharedPtr.h, which patch 0003 creates). --clean removes that
# state; the patches themselves are tracked files and are re-applied below.
if [ "$DO_CLEAN" = 1 ]; then
    SAVE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gamenative"
    mkdir -p "$SAVE_DIR"
    SAVE="$SAVE_DIR/gamescope-clean-$(date +%Y%m%d-%H%M%S).patch"
    git -C "$GS_DIR" diff > "$SAVE"
    if [ -s "$SAVE" ]; then
        echo "clean: discarded diff saved to $SAVE ($(wc -l < "$SAVE") lines)"
    else
        rm -f "$SAVE"
    fi
    echo "clean: removing untracked build state:"
    git -C "$GS_DIR" clean -fdn | awk '!/android\/patches/' | sed 's/^/    /'
    # The patch train is the one tracked path that survives: an experiment under
    # android/patches is local work, and the reset would take both a changed
    # patch and an added one. Copied out first, put back after the clean.
    PATCHES_SAVED="$(mktemp -d "${TMPDIR:-/tmp}/gs-patches.XXXXXX")"
    cp -a "$GS_DIR/android/patches/." "$PATCHES_SAVED/"
    git -C "$GS_DIR" reset --hard
    git -C "$GS_DIR" clean -fd
    # The stamp is ignored (a local build record, never committed), and `clean`
    # leaves ignored paths alone — but a stamp that outlived the reset would tell
    # the next run every patch is already applied, on a tree that is not patched.
    rm -f "$PATCH_STAMP"
    rm -rf "$GS_DIR/android/patches"
    mkdir -p "$GS_DIR/android/patches"
    cp -a "$PATCHES_SAVED/." "$GS_DIR/android/patches/"
    rm -rf "$PATCHES_SAVED"
    if [ -d "$GS_DIR/subprojects/wlroots/.git" ] || [ -f "$GS_DIR/subprojects/wlroots/.git" ]; then
        git -C "$GS_DIR/subprojects/wlroots" reset --hard
        git -C "$GS_DIR/subprojects/wlroots" clean -fd
    fi
    rm -rf "$GS_DIR/$BUILD_DIR"
    # meson applies a wrap's patch_directory overlay only when it first extracts
    # the wrap; a subproject dir that survives the clean is used as-is, so its
    # overlay is re-applied from the tracked packagefiles here — stb has no
    # meson.build of its own and the next setup would otherwise fail.
    for wrap in "$GS_DIR"/subprojects/*.wrap; do
        [ -f "$wrap" ] || continue
        patch_dir=$(sed -n 's/^ *patch_directory *= *//p' "$wrap")
        [ -n "$patch_dir" ] || continue
        dir=$(sed -n 's/^ *directory *= *//p' "$wrap")
        [ -n "$dir" ] || dir=$(basename "$wrap" .wrap)
        if [ -d "$GS_DIR/subprojects/packagefiles/$patch_dir" ] && \
           [ -d "$GS_DIR/subprojects/$dir" ]; then
            cp -a "$GS_DIR/subprojects/packagefiles/$patch_dir/." "$GS_DIR/subprojects/$dir/"
        fi
    done
    echo "clean: tree at $(git -C "$GS_DIR" rev-parse --short HEAD), build dir '$BUILD_DIR' removed"
fi

# --- 1. patch train -------------------------------------------------------
# Every patch applied here is recorded in an ignored stamp (name + blob hash),
# so a second run skips it by the stamp instead of a reverse-apply check: a
# later patch that edits lines inside an earlier hunk makes that check fail
# although the tree is right. --clean removes the stamp; a patch whose content
# changed falls back to the apply / reverse-apply checks.
apply_patch_once() {
    local p="$1" label="$2"
    local sig
    sig="$(basename "$p") $(git -C "$GS_DIR" hash-object "$p")"
    if [ -f "$PATCH_STAMP" ] && grep -qxF "$sig" "$PATCH_STAMP"; then
        echo "already applied: $label"
        return 0
    fi
    if git -C "$GS_DIR" apply --check "$p" 2>/dev/null; then
        git -C "$GS_DIR" apply "$p"
        echo "applied $label"
    elif git -C "$GS_DIR" apply -R --check "$p" 2>/dev/null; then
        echo "already applied: $label"
    else
        echo "PATCH DOES NOT APPLY: $p" >&2
        exit 1
    fi
    echo "$sig" >> "$PATCH_STAMP"
}
if [ "$SKIP_PATCHES" = 0 ]; then
    for p in "$GS_DIR"/android/patches/gamescope/*.patch; do
        apply_patch_once "$p" "$(basename "$p")"
    done
    # opt-in diagnostics train (android/patches/diagnostics/) — same apply
    # idiom, on top of the train, only when --include-diagnostics is given.
    if [ "$INCLUDE_DIAGNOSTICS" = 1 ]; then
        for p in "$GS_DIR"/android/patches/diagnostics/*.patch; do
            [ -e "$p" ] || continue
            apply_patch_once "$p" "diagnostics/$(basename "$p")"
        done
    fi
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
    # Release: meson defaults to `debug` (-O0, asserts on), and the composite
    # path runs per frame.
    --buildtype=release
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
