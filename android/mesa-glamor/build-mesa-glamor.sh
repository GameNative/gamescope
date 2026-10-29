#!/usr/bin/env bash
# NDK cross-build of the minimal GL/EGL/GBM stack Xwayland's glamor runs on:
# the pinned upstream Mesa release (fetch-mesa.sh) with patches/ applied,
# gallium zink + softpipe only, no LLVM.
#
# Installs into a stage prefix that package-gamescope.sh reads
# (GN_MESA_GLAMOR_STAGE):
#   lib/libEGL_mesa.so.0       glvnd EGL vendor (EGL_PLATFORM_GBM_KHR)
#   lib/libgallium-<ver>.so    gallium megadriver, glapi built in
#   lib/libgbm.so.1, libgbm.so GBM
#   lib/gbm/dri_gbm.so         GBM dri backend, found as libgbm's gbm/ sibling
#   lib/dri/libdril_dri.so     DRI megadriver (+ zink/swrast/kms_swrast names)
#   share/glvnd/egl_vendor.d/50_mesa.json
#
# Runs on Linux or macOS. bison and flex come from PATH (macOS ships bison 2.3,
# put Homebrew's first). meson >= 1.4 and the Python modules Mesa's build imports
# (mako, PyYAML, packaging) are provisioned into a venv in the work dir, because
# a host `meson` runs on whichever interpreter owns it and that one usually has
# none of them.
#
# Env overrides:
#   NDK                    NDK root (default: $HOME/Android/Sdk/ndk/27.3.13750724)
#   TERMUXFS               aarch64 prefix with libdrm + libglvnd headers
#   GN_MESA_GLAMOR_ROOT    work dir (default: <gamescope>/build-android-mesa-glamor)
#   GN_MESA_GLAMOR_STAGE   install prefix (default: <work dir>/stage)
#   GN_MESA_TARBALL_DIR    where the release tarball is kept (default: work dir)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS_DIR="$(cd "$HERE/../.." && pwd)"
NDK="${NDK:-$HOME/Android/Sdk/ndk/27.3.13750724}"
TERMUXFS="${TERMUXFS:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
ROOT="${GN_MESA_GLAMOR_ROOT:-$GS_DIR/build-android-mesa-glamor}"
STAGE="${GN_MESA_GLAMOR_STAGE:-$ROOT/stage}"
BUILD_DIR="$ROOT/build"

case "$(uname -s)" in
    Darwin) NDK_HOST=darwin-x86_64 ;;
    *)      NDK_HOST=linux-x86_64 ;;
esac
NDK_BIN="$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin"
[ -x "$NDK_BIN/aarch64-linux-android28-clang" ] || { echo "NDK not found at $NDK" >&2; exit 1; }
[ -d "$TERMUXFS/include/libdrm" ] || { echo "no libdrm headers under $TERMUXFS" >&2; exit 1; }
BISON="$(command -v bison)" || { echo "bison not in PATH" >&2; exit 1; }
FLEX="$(command -v flex)" || { echo "flex not in PATH" >&2; exit 1; }
CCACHE="$(command -v ccache || true)"

# Mesa's build imports mako, PyYAML and packaging, and needs meson >= 1.4. A bare
# `meson` from PATH runs on whichever python owns it (here the distro's, which
# has neither the modules nor a recent enough version), so the build tools live
# in a venv in the work dir and come first in PATH. The venv host must be an
# interpreter that can bootstrap pip: a bundled runtime python (no ensurepip)
# cannot, so the distro interpreter wins when it exists.
VENV="$ROOT/venv"
if [ ! -x "$VENV/bin/meson" ]; then
    PYTHON=/usr/bin/python3
    [ -x "$PYTHON" ] || PYTHON=python3
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV" || {
        echo "cannot create the Mesa build-tool venv with $PYTHON (it needs the" >&2
        echo "venv module and ensurepip; Debian/Ubuntu: apt-get install python3-venv)" >&2
        exit 1; }
    "$VENV/bin/pip" install --quiet 'meson>=1.4,<2' mako pyyaml packaging
fi
PATH="$VENV/bin:$PATH"

SRC="$(bash "$HERE/fetch-mesa.sh" "$ROOT" | tail -1)"

CROSS="$ROOT/cross-aarch64-linux-android.txt"
sed -e "s|@CCACHE@|${CCACHE:+'$CCACHE', }|g" \
    -e "s|@NDK_BIN@|$NDK_BIN|g" \
    -e "s|@BISON@|$BISON|g" \
    -e "s|@FLEX@|$FLEX|g" \
    -e "s|@DEPS@|$TERMUXFS|g" \
    -e "s|@OVERLAY@|$HERE/overlay|g" \
    "$HERE/cross.txt.in" > "$CROSS"
if grep -q '@[A-Z_]*@' "$CROSS"; then
    echo "cross file still has unsubstituted placeholders: $CROSS" >&2
    exit 1
fi

# platforms=            glamor talks EGL + GBM only, no X11/Wayland platform
# gbm=enabled           gives EGL the GBM platform (platform_drm.c)
# llvm=disabled         keeps libLLVM out of libgallium
# glvnd=enabled         EGL is libEGL_mesa.so.0 + 50_mesa.json
# xmlconfig/expat/zstd  dropped to keep the closure to bionic + libdrm
# The source tree is extracted fresh on every run, so the build dir is too.
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$SRC" \
    --cross-file "$CROSS" \
    -Dprefix="$STAGE" \
    -Dbuildtype=release \
    -Dplatforms= \
    -Degl=enabled -Dgbm=enabled \
    -Dgles2=enabled -Dgles1=disabled -Dopengl=false -Dglx=disabled \
    -Dgallium-drivers=zink,softpipe \
    -Dvulkan-drivers= \
    -Dshared-glapi=enabled \
    -Dglvnd=enabled \
    -Dllvm=disabled \
    -Dvalgrind=disabled \
    -Dzstd=disabled \
    -Dxmlconfig=disabled -Dexpat=disabled \
    -Dgallium-va=disabled \
    -Dgallium-rusticl=false \
    -Dgallium-d3d10umd=false \
    -Dtools= \
    -Dbuild-tests=false -Dlmsensors=disabled -Dperfetto=false \
    -Dandroid-libbacktrace=disabled

ninja -C "$BUILD_DIR"
rm -rf "$STAGE"
ninja -C "$BUILD_DIR" install

# A path of this build host baked into a shipped library does not exist on the
# device; package-gamescope.sh refuses such files, so fail here first.
leak=0
while IFS= read -r f; do
    if strings -a "$f" | grep -qF -e "$GS_DIR" -e "$ROOT" -e "$TERMUXFS" -e "$NDK"; then
        echo "build path baked into ${f#$STAGE/}" >&2
        leak=1
    fi
done < <(find "$STAGE/lib" -type f -name '*.so*')
[ "$leak" = 0 ] || exit 1

echo "=== stage: $STAGE"
(cd "$STAGE" && find lib share -type f -o -type l | sort)
