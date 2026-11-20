#!/usr/bin/env bash
# NDK cross-build of the GL library a *guest* loads: Mesa zink with GLX + DRI3,
# i.e. the kopper path, as one monolithic libGL.so.1.5.0.
#
# Why this exists: the container image ships Mesa 24.3's classic libGL (glx/xlib
# frontend on winsys/sw/xlib, presenting with XShmPutImage). A GL guest then
# renders through zink on a headless Vulkan instance and copies the result into
# the X server, so its frames never create a Vulkan surface -- the ICD shim sees
# no swapchain, applies no acquire cap, generates nothing and never gets a release
# note. Kopper (zink's own WSI) presents through GLX/DRI3 instead: the client
# creates a VkSurfaceKHR from its X window, which the shim already serves
# (VK_KHR_xcb_surface, gamenative-drm#35), so GL rides the same ring and the same
# gate as a Vulkan guest.
#
# The source, cross file and patch set are the ones android/mesa-glamor already
# uses (pinned upstream tarball, fetch-mesa.sh), so both Mesas in the payload are
# one version and one toolchain.
#
# Installs into a stage prefix:
#   lib/libGL.so.1.5.0, libGL.so.1, libGL.so     the GL/GLX client, glapi built in
#   lib/dri/zink_dri.so                          the swrast-free DRI driver
#   share/glvnd/...                              absent: glvnd is disabled on purpose
#
# Env overrides are the same as build-mesa-glamor.sh: NDK, TERMUXFS,
# GN_MESA_GL_ROOT (work dir), GN_MESA_GL_STAGE (install prefix).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS_DIR="$(cd "$HERE/../.." && pwd)"
GLAMOR="$GS_DIR/android/mesa-glamor"
NDK="${NDK:-$HOME/Android/Sdk/ndk/27.3.13750724}"
TERMUXFS="${TERMUXFS:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
ROOT="${GN_MESA_GL_ROOT:-$GS_DIR/build-android-mesa-gl}"
STAGE="${GN_MESA_GL_STAGE:-$ROOT/stage}"
BUILD_DIR="$ROOT/build"

case "$(uname -s)" in
    Darwin) NDK_HOST=darwin-x86_64 ;;
    *)      NDK_HOST=linux-x86_64 ;;
esac
NDK_BIN="$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin"
[ -x "$NDK_BIN/aarch64-linux-android28-clang" ] || { echo "NDK not found at $NDK" >&2; exit 1; }
[ -d "$TERMUXFS/include/libdrm" ] || { echo "no libdrm headers under $TERMUXFS" >&2; exit 1; }
[ -f "$TERMUXFS/include/xcb/xcb.h" ] || { echo "no libxcb headers under $TERMUXFS" >&2; exit 1; }
[ -f "$TERMUXFS/include/GL/glx.h" ] || {
    echo "no GL/glx.h under $TERMUXFS/include — GLX needs the libGL headers" >&2; exit 1; }
BISON="$(command -v bison)" || { echo "bison not in PATH" >&2; exit 1; }
FLEX="$(command -v flex)" || { echo "flex not in PATH" >&2; exit 1; }
CCACHE="$(command -v ccache || true)"

# Same build-tool venv rule as the glamor build: Mesa imports mako/PyYAML and
# needs meson >= 1.4, and a bare `meson` from PATH runs on an interpreter that
# usually has neither.
VENV="$ROOT/venv"
if [ ! -x "$VENV/bin/meson" ]; then
    PYTHON=/usr/bin/python3
    [ -x "$PYTHON" ] || PYTHON=python3
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV" || { echo "cannot create the build-tool venv" >&2; exit 1; }
    "$VENV/bin/pip" install --quiet 'meson>=1.4,<2' mako pyyaml packaging
fi
PATH="$VENV/bin:$PATH"

# Short-circuit so the pinned tarball and its patches are shared, not refetched.
SRC="$(bash "$GLAMOR/fetch-mesa.sh" "$ROOT" | tail -1)"

CROSS="$ROOT/cross-aarch64-linux-android.txt"
sed -e "s|@CCACHE@|${CCACHE:+'$CCACHE', }|g" \
    -e "s|@NDK_BIN@|$NDK_BIN|g" \
    -e "s|@BISON@|$BISON|g" \
    -e "s|@FLEX@|$FLEX|g" \
    -e "s|@DEPS@|$TERMUXFS|g" \
    -e "s|@OVERLAY@|$GLAMOR/overlay|g" \
    "$GLAMOR/cross.txt.in" > "$CROSS"
if grep -q '@[A-Z_]*@' "$CROSS"; then
    echo "cross file still has unsubstituted placeholders: $CROSS" >&2
    exit 1
fi

# The glamor build looks only at the overlay's .pc files, because the prefix's
# add -I${includedir} and break C++. This build needs the prefix's real ones --
# x11, xcb, xshmfence and the DRI protocol packages have no overlay copy -- and it
# compiles C only, so that hazard does not apply. Overlay stays first so libdrm
# still comes from it.
python3 - "$CROSS" "$TERMUXFS" <<'EOF'
import sys, re
path, deps = sys.argv[1], sys.argv[2]
text = open(path).read()
want = "pkg_config_libdir = ['%s/overlay/pkgconfig', '%s/lib/pkgconfig']" % (
    re.search(r"-I([^']*)/overlay/include", text).group(1), deps)
text = re.sub(r"pkg_config_libdir = \[[^\]]*\]", want, text)
open(path, "w").write(text)
print("pkg_config_libdir:", want)
EOF

# platforms=x11   the GLX client talks X directly; this is what the glamor build
#                 turns off because glamor is EGL+GBM only
# glx=dri         GLX with a DRI backend -- the frontend that carries kopper.
#                 'disabled' means no GLX at all, 'xlib' would mean an indirect
#                 server-side path that presents by copy
# opengl=true     build libGL; without it there is no client library
# glvnd=disabled  one monolithic libGL.so.1.5.0, the shape the container image
#                 already has, so nothing has to learn about libGLX_mesa
# vulkan-drivers= zink dlopens the system ICD at runtime
# gbm/egl         kept off: a GLX client needs neither, and every library the
#                 payload ships has to resolve inside it (check-payload-closure)
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$SRC" \
    --cross-file "$CROSS" \
    -Dprefix="$STAGE" \
    -Dbuildtype=release \
    -Dplatforms=x11 \
    -Dglx=dri \
    -Dopengl=true \
    -Dgles1=disabled -Dgles2=disabled \
    -Degl=disabled -Dgbm=disabled \
    -Dgallium-drivers=zink \
    -Dvulkan-drivers= \
    -Dshared-glapi=disabled \
    -Dglvnd=disabled \
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

ninja -C "$BUILD_DIR" install

echo "staged: $STAGE"
ls -l "$STAGE/lib"/libGL.so* "$STAGE/lib/dri" 2>/dev/null || true
