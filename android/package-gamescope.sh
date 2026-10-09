#!/usr/bin/env bash
# package-gamescope.sh — produce the GameNative-bundled gamescope payload:
#
#   1. <GameNative>/app/src/main/assets/gamescope-gamenative-<date>.tzst
#      tar+zstd rooted at bin/ lib/ share/ (extracted to filesDir/gamescope/
#      by XServerScreen.refreshComponentsFiles — the pulseaudio pattern).
#   2. <GameNative>/app/src/main/jniLibs/arm64-v8a/libgamenative_drm.so
#      (from gamenative-drm's tools/build-android.sh; 16 KB pages).
#
# The sibling projects are expected next to this checkout; each is overridable
# with the env var named beside it.
#
# Usage: android/package-gamescope.sh [YYYYMMDD]   (default: today)
#
# Library resolution is recursive over DT_NEEDED, pulling from the termux
# prefix and the NDK sysroot, skipping bionic/NDK-public system libs
# (loaded from /system/lib64 on device) and libvulkan.so (the imagefs
# loader+turnip ICD stays the session's vulkan stack for wine). The gamescope
# binary's prefix rpath is a build-time path that won't exist on device;
# runtime resolution comes from LD_LIBRARY_PATH, which the launcher prepends
# with filesDir/gamescope/lib (LD_LIBRARY_PATH beats DT_RUNPATH — no patchelf).
#
# Mesa GL/EGL for Xwayland's glamor: glamor dlopens libEGL.so.1 by exact
# SONAME, so the payload ships glvnd's loader (libEGL.so.1) + GLES shims from
# the termux prefix, and Mesa's EGL vendor (libEGL_mesa.so.0, per the shipped
# 50_mesa.json), libgallium, libgbm, libglapi, the gbm/dri_gbm backend and the
# DRI drivers under lib/dri from the STAGED minimal Mesa (GN_MESA_GLAMOR_STAGE,
# Projects/mesa/build-android-glamor/stage) — zink+softpipe, LLVM disabled. That
# stage has no libLLVM/libxml2/libicu dependency, unlike the prefix's
# libgallium-25.3.5, so those are no longer shipped. zink dlopens
# libvulkan.so.1 (a name Android does not provide — its loader is libvulkan.so),
# so the payload carries Mesa's loader explicitly.

set -euo pipefail

GS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WS_DIR="$(dirname "$GS_DIR")"
GNDRM_DIR="${GNDRM_DIR:-$WS_DIR/gamenative-drm}"
GN_DIR="${GN_DIR:-$WS_DIR/GameNative}"
DEPS="${GAMESCOPE_TERMUX_PREFIX:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
# Staged minimal Mesa (Projects/mesa, target build-android-glamor/stage): zink +
# softpipe gallium, glvnd EGL/GBM platform, LLVM DISABLED. The packager prefers
# this stage for every Mesa/GBM file it provides, so the payload no longer
# carries the termux prefix's LLVM-bound Mesa (libgallium-25.3.5 + libLLVM +
# libxml2/libicu). libglvnd's loader/GLES libs and everything else still come
# from the prefix.
GN_MESA_GLAMOR_STAGE="${GN_MESA_GLAMOR_STAGE:-$WS_DIR/mesa/build-android-glamor/stage}"
DATE="${1:-$(date +%Y%m%d)}"
ASSET_NAME="gamescope-gamenative-$DATE.tzst"
OUT_ASSETS="$GN_DIR/app/src/main/assets"
OUT_JNILIBS="$GN_DIR/app/src/main/jniLibs/arm64-v8a"
# Reproducibility: identical inputs must yield a byte-identical .tzst. The
# archive is normalised (fixed mtime, sorted order, uid/gid 0) below, so the
# filename's date argument does not affect the bytes. A caller-supplied
# SOURCE_DATE_EPOCH wins; else derive it from the tree so rebuilds match.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$GS_DIR" log -1 --format=%ct 2>/dev/null || echo 0)}"

NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
    NDK="$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
SYSROOT_LIBS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"

GAMESCOPE_BIN="$GS_DIR/build-android/src/gamescope"
REAPER_BIN="$GS_DIR/build-android/src/gamescopereaper"
SHIM_SO="$GNDRM_DIR/target/shim/android/aarch64/libgndrm_shim.so"
GNDRM_REL="$GNDRM_DIR/target/aarch64-linux-android/release"
DRM_SO="$GNDRM_REL/libgamenative_drm.so"
ICD_SO="$GNDRM_REL/libadrenotools_gamescope.so"
DMTEST_BIN="$GNDRM_REL/gn-dmabuf-test"
WSITEST_BIN="$GNDRM_REL/gn-wsi-test"
XTREE_BIN="$GNDRM_REL/gn-xtree-probe"

# --- prerequisites (build whatever is missing) ------------------------------
[ -x "$GAMESCOPE_BIN" ] || bash "$GS_DIR/android/build-gamescope.sh"
[ -f "$SHIM_SO" ] || "$GNDRM_DIR/tools/build-shim.sh" android
# build-android.sh produces the gamenative-drm artifacts (cargo cdylibs + the
# guest clients, incl. gn-xtree-probe) in one invocation — run it if any is
# missing.
for f in "$DRM_SO" "$ICD_SO" "$DMTEST_BIN" "$WSITEST_BIN" "$XTREE_BIN"; do
    [ -f "$f" ] || { "$GNDRM_DIR/tools/build-android.sh"; break; }
done
for f in "$GAMESCOPE_BIN" "$REAPER_BIN" "$SHIM_SO" "$DRM_SO" "$ICD_SO" "$DMTEST_BIN" "$WSITEST_BIN" "$XTREE_BIN"; do
    [ -e "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

# --- staging ----------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"

cp "$GAMESCOPE_BIN" "$STAGE/bin/gamescope"
# gamescope spawns "gamescopereaper" via execvp PATH lookup (Utils/Process.cpp
# SpawnProcessInWatchdog); the launcher prepends this bin/ to PATH.
cp "$REAPER_BIN" "$STAGE/bin/gamescopereaper"
cp "$SHIM_SO" "$STAGE/lib/libgndrm_shim.so"

# --- recursive DT_NEEDED resolver -------------------------------------------
# Search order for a given SONAME: the staged minimal Mesa first (so its Mesa/GBM
# files win over the prefix's), then the termux prefix, then the NDK sysroot.
find_lib() {
    local name="$1" p
    p="$(find "$GN_MESA_GLAMOR_STAGE/lib" -maxdepth 1 -name "$name" 2>/dev/null | head -1)"
    [ -n "$p" ] && { printf '%s' "$p"; return; }
    p="$(find "$DEPS/lib" -maxdepth 1 -name "$name" 2>/dev/null | head -1)"
    [ -n "$p" ] && { printf '%s' "$p"; return; }
    find "$SYSROOT_LIBS" -name "$name" 2>/dev/null | head -1
}

resolve_libs() {
    local queue=("$@") name path elf
    local -A seen=()
    while ((${#queue[@]})); do
        elf="${queue[0]}"; queue=("${queue[@]:1}")
        while read -r name; do
            [ -n "$name" ] || continue
            case "$name" in
                # bionic / NDK-public system libs (present on every device).
                # NB: libz.so.1 is NOT system-provided (Android ships libz.so
                # with SONAME libz.so only) — libgallium NEEDs libz.so.1, so it
                # must be shipped; only bare libz.so is skipped.
                libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libz.so|\
                ld-android.so)
                    continue ;;
                # libsync.so: the device's /system/lib64/libsync.so is the
                # real provider (exports sync_wait, which libui.so NEEDs). The
                # NDK sysroot ships only a versioned STUB (sync_merge/
                # sync_file_info/sync_file_info_free @@LIBSYNC, no sync_wait,
                # DT_NEEDED on itself) under <api>/libsync.so. The staged
                # libgallium-25.0.0-devel.so NEEDs libsync.so, so without this
                # skip the resolver copies the stub into lib/, where it shadows
                # /system/lib64/libsync.so by SONAME and breaks libui's import
                # (gamescope cannot exec: cannot locate symbol "sync_wait").
                libsync.so)
                    continue ;;
                # gamescope must share the imagefs vulkan loader + turnip ICD
                # for the WINE/guest path. The zink GL driver's libvulkan.so.1
                # is staged explicitly below, outside this resolver.
                libvulkan.so|libvulkan.so.*)
                    continue ;;
                # wine-internal unix libs (resolved from wine's own lib dir)
                ntdll.so|win32u.so|libwine.so*)
                    continue ;;
            esac
            [ "${seen[$name]:-}" ] && continue
            seen[$name]=1
            path="$(find_lib "$name")"
            if [ -z "$path" ]; then
                echo "  UNRESOLVED: $name (needed by ${elf##*/})" >&2
                continue
            fi
            cp -L "$path" "$STAGE/lib/$name"
            queue+=("$STAGE/lib/$name")
        done < <(readelf -d "$elf" | grep NEEDED | sed -E 's/.*\[(.*)\]/\1/')
    done
}
resolve_libs "$STAGE/bin/gamescope" "$STAGE/bin/gamescopereaper"

# --- Mesa GL/EGL stack for Xwayland glamor ----------------------------------
# Xwayland's glamor dlopens "libEGL.so.1" by exact SONAME (glvnd loader). The
# glvnd loader finds its vendor via __EGL_VENDOR_LIBRARY_DIRS (its compiled-in
# dirs are termux-prefix paths absent on device); the vendor's library_path in
# 50_mesa.json is "libEGL_mesa.so.0".
#
# The EGL vendor / gallium / GBM / glapi files come from the staged minimal Mesa
# (LLVM-free); libglvnd's loader + GLES shims are NOT built by that stage, so
# they still come from the termux prefix. libgbm.so.1 satisfies the DT_NEEDED of
# libEGL_mesa/libdril, and libgbm.so is the exact name Xwayland dlopens.
MESA_STAGE_SONAMES=(
    libEGL_mesa.so.0          # glvnd vendor, 50_mesa.json library_path
    libgallium-25.0.0-devel.so
    libgbm.so.1               # DT_NEEDED of libEGL_mesa / DRI drivers
    libgbm.so                 # Xwayland dlopens this exact name
    libglapi.so.0
)
GLVND_PREFIX_SONAMES=(
    libEGL.so.1               # the name glamor asks for (glvnd loader)
    libGLESv2.so.2
    libGLESv1_CM.so.1
    libGLdispatch.so.0
)
for n in "${MESA_STAGE_SONAMES[@]}"; do cp -L "$GN_MESA_GLAMOR_STAGE/lib/$n" "$STAGE/lib/$n"; done
for n in "${GLVND_PREFIX_SONAMES[@]}"; do cp -L "$DEPS/lib/$n" "$STAGE/lib/$n"; done
resolve_libs "${MESA_STAGE_SONAMES[@]/#/$STAGE/lib/}" \
             "${GLVND_PREFIX_SONAMES[@]/#/$STAGE/lib/}"

# zink renders GL over Vulkan→turnip (keeps the device GPU in the path). zink
# dlopens "libvulkan.so.1"; Android only ships libvulkan.so, so the payload
# carries Mesa's loader. It reads VK_ICD_FILENAMES, which the launcher points
# at the session's adrenotools shim json — the same ICD stack the rest of the
# session uses. (libvulkan.so itself stays skipped above for the wine path.)
cp -L "$DEPS/lib/libvulkan.so.1" "$STAGE/lib/libvulkan.so.1"
resolve_libs "$STAGE/lib/libvulkan.so.1"

# DRI drivers: the staged minimal Mesa ships one libdril_dri.so with the
# per-driver names as symlinks; the requested name selects the gallium driver.
# Ship libdril plus the names we select (zink primary, swrast/kms_swrast
# fallbacks) — replacing the prefix's full 42-driver set. LIBGL_DRIVERS_PATH
# (launcher) overrides the compiled-in prefix default.
mkdir -p "$STAGE/lib/dri"
cp -L "$GN_MESA_GLAMOR_STAGE/lib/dri/libdril_dri.so" "$STAGE/lib/dri/libdril_dri.so"
for d in zink_dri.so swrast_dri.so kms_swrast_dri.so; do
    ln -sfn libdril_dri.so "$STAGE/lib/dri/$d"
done
resolve_libs "$STAGE/lib/dri/libdril_dri.so"

# GBM DRI backend: libgbm dlopens the dri backend from its backend dir.
mkdir -p "$STAGE/lib/gbm"
cp -L "$GN_MESA_GLAMOR_STAGE/lib/gbm/dri_gbm.so" "$STAGE/lib/gbm/dri_gbm.so"
resolve_libs "$STAGE/lib/gbm/dri_gbm.so"

# glvnd EGL vendor json (library_path: libEGL_mesa.so.0, resolved from
# LD_LIBRARY_PATH = filesDir/gamescope/lib on device).
mkdir -p "$STAGE/share/glvnd/egl_vendor.d"
cp "$GN_MESA_GLAMOR_STAGE/share/glvnd/egl_vendor.d/50_mesa.json" \
   "$STAGE/share/glvnd/egl_vendor.d/"

# --- vulkan driver staging (04 §4.4) ------------------------------------------
# Every process in a GameScope session sees exactly one vulkan ICD — the
# adrenotools shim (VK_ICD_FILENAMES, assembled by the launcher). The shim
# picks per process: gamescope itself → the payload's bundled termux turnip
# (the only turnip build with wayland WSI); guests → the user-selected
# adrenotools driver — passthrough when it has VK_KHR_wayland_surface, the
# WSI proxy (client-side dma-buf swapchain: app renders straight into the
# shim-owned scan-out ring, presents attach/damage/commit on the game's own
# wl_surface, paced by wl_buffer.release) when it doesn't, payload-freedreno
# fallback otherwise.
#
# The shim and both guest smoke-test clients are Rust crates in gamenative-drm
# (icd_shim/ + utils/, built by its tools/build-android.sh — API 28, 16 KB
# pages, link-time wayland/vulkan from GAMESCOPE_TERMUX_PREFIX). The shim's
# NEEDEDs stay libc/libdl/libwayland-client — no libvulkan, every real
# driver call goes through function pointers.
cp "$DEPS/lib/libvulkan_freedreno.so" "$STAGE/lib/"
mkdir -p "$STAGE/share/vulkan/icd.d"
cat > "$STAGE/share/vulkan/icd.d/freedreno_icd.aarch64.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.354",
        "library_arch": "64",
        "library_path": "libvulkan_freedreno.so"
    },
    "file_format_version": "1.0.1"
}
EOF
cat > "$STAGE/share/vulkan/icd.d/adrenotools_gamescope.aarch64.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.3.0",
        "library_arch": "64",
        "library_path": "libadrenotools_gamescope.so"
    },
    "file_format_version": "1.0.1"
}
EOF

cp "$ICD_SO" "$STAGE/lib/libadrenotools_gamescope.so"
resolve_libs "$STAGE/lib/libadrenotools_gamescope.so" \
    "$STAGE/lib/libvulkan_freedreno.so"

# --- guest smoke-test clients (04 §4.4) ---------------------------------------
# bin/gn-dmabuf-test: client-dmabuf output-half smoke test; bin/gn-wsi-test:
# plain vulkan WSI client (swapchain clear-color presents) exercising the
# shim's whole proxy path as the session guest. Run via
# GUEST_PROGRAM_LAUNCHER_COMMAND=<filesDir>/gamescope/bin/gn-{dmabuf,wsi}-test.
# bin/gn-xtree-probe: X window-tree evidence client (why gamescope does/doesn't
# see the app's window); links the payload's libxcb, run via
#   run-as app.gamenative <filesDir>/gamescope/bin/gn-xtree-probe -display :0
# (LD_LIBRARY_PATH=<filesDir>/gamescope/lib).
cp "$DMTEST_BIN" "$STAGE/bin/gn-dmabuf-test"
cp "$WSITEST_BIN" "$STAGE/bin/gn-wsi-test"
cp "$XTREE_BIN" "$STAGE/bin/gn-xtree-probe"
resolve_libs "$STAGE/bin/gn-dmabuf-test" "$STAGE/bin/gn-wsi-test" "$STAGE/bin/gn-xtree-probe"

# --- data files --------------------------------------------------------------
# gamescope's own installed data (shaders, base EDID, …) via meson install
DESTDIR="$WORK/install"
mkdir -p "$DESTDIR"
meson install -C "$GS_DIR/build-android" --destdir "$(cd "$DESTDIR" && pwd)" --quiet >/dev/null
find "$DESTDIR" -type d -name gamescope -path "*/share/*" -exec cp -a {} "$STAGE/share/" \; 2>/dev/null || true
# Keymap data for libxkbcommon (gamescope seat + winewayland keymaps read
# these at runtime — XKB_CONFIG_ROOT in the launcher points here; the
# compiled fallback path is prefix-rewritten below)
[ -d "$DEPS/share/xkeyboard-config-2" ] && cp -a "$DEPS/share/xkeyboard-config-2" "$STAGE/share/"
# libxkbcommon's compiled XKB root is <prefix>/share/X11/xkb — upstream an
# ABSOLUTE symlink into the termux prefix, dangling on device. Recreate it
# as a relative symlink at our in-package copy. (The rest of share/X11 —
# locale etc. — was XWayland-era and is no longer staged.)
mkdir -p "$STAGE/share/X11"
ln -sfn ../xkeyboard-config-2 "$STAGE/share/X11/xkb"
# PNP ID table for monitor names (patch A9: launcher points
# GAMESCOPE_PNP_IDS_PATH at this — the compiled HWDATA_PNP_IDS prefix path
# doesn't exist on device)
mkdir -p "$STAGE/share/hwdata"
[ -f "$DEPS/share/hwdata/pnp.ids" ] && cp "$DEPS/share/hwdata/pnp.ids" "$STAGE/share/hwdata/"

# --- termux prefix rewrite ----------------------------------------------------
# REMOVED (2026-09-25): payload binaries/libs carry compiled-in paths under the
# build prefix (/data/data/com.termux/files/usr/...) — gamescope's HWDATA_PNP_IDS,
# libxkbcommon/libxkbregistry's XKB data root, SCRIPT_DIR/lua module paths. Every
# runtime-relevant one is env-overridden by the launcher instead
# (GAMESCOPE_PNP_IDS_PATH, patch A9; XKB_CONFIG_ROOT — honored by both
# libxkbcommon and libxkbregistry), and SCRIPT_DIR/lua is unused. The old
# equal-length rewrite to /data/data/app.gamenative/f/g/x + launcher symlink is
# gone; nothing resolves under the termux prefix on device anymore.

# --- XWayland payload (doc 05), bundled at the same prefix -------------------
# The Xwayland package is built by gamenative-xwayland/android/package-xwayland.sh
# (bin/Xwayland + bin/xkbcomp + lib/ + share/X11/xkb data + tmp/xkb workdir,
# runtime prefix files/gamescope — same as gamescope itself). Absorb its stage
# into this package root so GameNative ships a single gamescope asset.
XW_DIR="${GN_XWAYLAND_DIR:-$WS_DIR/gamenative-xwayland}"
[ -x "$XW_DIR/build-android/hw/xwayland/Xwayland" ] || bash "$XW_DIR/android/build-xwayland.sh"
bash "$XW_DIR/android/package-xwayland.sh" "$DATE" >/dev/null
XW_TZST="$OUT_ASSETS/xwayland-gamenative-$DATE.tzst"
[ -f "$XW_TZST" ] || { echo "error: xwayland payload $XW_TZST not produced" >&2; exit 1; }
tar --zstd -C "$STAGE" -xf "$XW_TZST"
rm -f "$XW_TZST"

# --- staged-Mesa authority re-assert + guard ---------------------------------
# The absorbed Xwayland payload carries its OWN resolver output, and that
# resolver (package-xwayland.sh) searches only the termux prefix: Xwayland
# DT_NEEDEDs libgbm.so, so the Xwayland payload's lib/libgbm.so is the
# prefix's 14,296-byte self-referential stub (no gbm.c gate patch) — the
# extraction above therefore clobbered the patched staged libgbm.so that line
# 172 had just staged. libgbm.so.1 survived only because the prefix has no
# versioned SONAME. The staged minimal Mesa is authoritative for every file it
# provides, so re-assert the MESA_STAGE_SONAMES from the stage after the
# absorption (the same copy step line 172 performs), then verify byte-identity
# of every stage-sourced file. A future clobber, or a reordered staging step,
# fails the build here instead of shipping silently — the class-check that
# would also have caught the earlier libsync defect.
for n in "${MESA_STAGE_SONAMES[@]}"; do
    src="$GN_MESA_GLAMOR_STAGE/lib/$n"
    [ -e "$src" ] || continue
    cp -L "$src" "$STAGE/lib/$n"
done

check_stage_sourced() { # <staged-path> <stage-source>
    local a="$1" b="$2"
    cmp -s "$a" "$b" && return
    echo "GUARD FAIL: $a is not byte-identical to its stage source $b" >&2
    echo "  staged: $(md5sum "$a" 2>/dev/null)" >&2
    echo "  source: $(md5sum "$b" 2>/dev/null)" >&2
    exit 1
}
for n in "${MESA_STAGE_SONAMES[@]}"; do
    [ -e "$GN_MESA_GLAMOR_STAGE/lib/$n" ] || continue
    check_stage_sourced "$STAGE/lib/$n" "$GN_MESA_GLAMOR_STAGE/lib/$n"
done
for f in "$STAGE"/lib/dri/*.so; do
    [ -e "$f" ] || continue
    check_stage_sourced "$f" "$GN_MESA_GLAMOR_STAGE/lib/dri/${f##*/}"
done
check_stage_sourced "$STAGE/lib/gbm/dri_gbm.so" "$GN_MESA_GLAMOR_STAGE/lib/gbm/dri_gbm.so"
echo "guard: stage-sourced Mesa/GBM/DRI files are byte-identical to their staged sources"

# --- archive + jniLib --------------------------------------------------------
mkdir -p "$OUT_ASSETS" "$OUT_JNILIBS"
# Only one payload is ever live (XServerScreen.kt names exactly one); drop
# stale archives so they don't pile up in the repo/APK.
rm -f "$OUT_ASSETS"/gamescope-gamenative-*.tzst
# --- guard: no build-host paths in the stage-sourced Mesa files --------------
# Configure-time prefixes (DEFAULT_BACKENDS_PATH, PIPE_SEARCH_DIR) bake the build
# host's staging tree into a binary; on device that path does not exist and the
# dlopen fails (MESA-LOADER: failed to open dri: ... not found). The staged Mesa
# files must resolve their dirs at runtime from their own location
# (loader_get_sibling_dir), so fail loudly if a host path survives.
# Scope: only the stage-sourced Mesa set -- the Rust shim/ICD binaries embed
# source paths in panic messages by design.
BUILD_PATH_FAIL=0
for f in "${MESA_STAGE_SONAMES[@]/#/$STAGE/lib/}" "$STAGE"/lib/dri/*.so \
         "$STAGE/lib/gbm/dri_gbm.so"; do
    [ -f "$f" ] || continue
    h=$(strings -a "$f" 2>/dev/null | grep -cE '/data/workspace|/home/' || true)
    if [ "$h" != 0 ]; then
        echo "  BUILD-HOST PATH in ${f##*/}: $h occurrence(s)" >&2
        BUILD_PATH_FAIL=1
    fi
done
[ "$BUILD_PATH_FAIL" = 0 ] || {
    echo "FAIL: staged Mesa files carry build-host paths" >&2; exit 1; }

# --- page-size gate ----------------------------------------------------------
# Android 15+ devices use 16 KB pages, and a library whose LOAD segments are
# aligned below that cannot be mapped at all. Everything this script builds is
# linked with -Wl,-z,max-page-size=16384 (the cross files, the daemon's
# RUSTFLAGS); the files it copies out of the termux prefix are the ones that can
# lag, so the staged tree is gated here.
PS_BELOW=0
while IFS= read -r f; do
    [ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
    a=$(LC_ALL=C readelf -lW "$f" 2>/dev/null \
        | awk '$1=="LOAD"{v=strtonum($NF); if(v<m||m==0)m=v} END{print m+0}')
    [ "$a" -ge 16384 ] && continue
    echo "  BELOW 16 KB: ${f#$STAGE/} (LOAD p_align=0x$(printf %x "$a"))" >&2
    PS_BELOW=1
done < <(find "$STAGE" -type f)
[ "$PS_BELOW" = 0 ] || {
    echo "FAIL: staged ELF(s) below 16 KB page alignment — rebuild the source with" >&2
    echo "      -Wl,-z,max-page-size=16384 (a termux-prefix package: refresh it)" >&2
    exit 1; }

# --- permission normalization ------------------------------------------------
# The staged tree inherits its modes from its sources (termux prefix, meson
# install, the absorbed Xwayland payload): directories 0700, plain files 0600,
# libraries 0700. tar stores those verbatim, so the payload could ship a
# read-only, owner-only tree — and the app cannot replace such a tree (a
# recursive delete is a silent no-op on files it cannot write), so a stale
# payload survives. Normalize the archive to the modes it is meant to ship:
# directories 0755, regular files 0644, executable files 0755. Symlinks are
# left untouched (tar stores them as symlinks regardless of their mode).
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -perm /111 -exec chmod 0755 {} +
find "$STAGE" -type f ! -perm /111 -exec chmod 0644 {} +

# Reproducible archive: fixed mtime (SOURCE_DATE_EPOCH), entries sorted by name,
# uid/gid 0, so identical staged content packs to identical bytes regardless of
# build timing or filesystem readdir order. --mtime overrides every member's
# mtime; --sort=name fixes the directory walk order.
tar --owner=0 --group=0 --numeric-owner --sort=name \
    --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE" -cf - bin lib share tmp \
    | zstd -19 -T0 -o "$OUT_ASSETS/$ASSET_NAME"
cp "$DRM_SO" "$OUT_JNILIBS/libgamenative_drm.so"

# --- report ------------------------------------------------------------------
echo "--- contents ---"
du -sh "$STAGE/bin" "$STAGE/lib" "$STAGE/share"
echo "bins: $(ls "$STAGE/bin" | tr '\n' ' ')"
echo "libs: $(ls "$STAGE/lib" | wc -l) files"
ls -lh "$OUT_ASSETS/$ASSET_NAME" "$OUT_JNILIBS/libgamenative_drm.so"
echo
echo "NOTE: XServerScreen.kt hardcodes the dated asset name (pulseaudio pattern)."
grep -oE "gamescope-gamenative-[0-9a-z]*\.tzst" \
    "$GN_DIR/app/src/main/java/app/gamenative/ui/screen/xserver/XServerScreen.kt" \
    | sort -u || true
echo "If that differs from $ASSET_NAME, update refreshComponentsFiles."
