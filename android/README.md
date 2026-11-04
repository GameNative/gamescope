# Android port

Patches, cross-compilation and packaging that let gamescope run on an Android
device as a display server: it serves its DRM backend from a userspace DRM device
supplied by the host application, and composites the game's X11 window (through
XWayland) onto the host's surface.

The tree is kept close to the upstream base — every change is a patch, applied in
filename order.

## Layout

| path | what |
|---|---|
| `patches/gamescope/` | the gamescope patch series (`NNNN-<tag>-<slug>.patch`) |
| `patches/wlroots/` | the wlroots submodule's patch series |
| `cross/` | the meson cross file for `aarch64-linux-android` |
| `stubs/` | a libudev stub (source + header) for code paths that still compile it |
| `build-gamescope.sh` | applies the series and configures/builds the prefix build |
| `package-gamescope.sh` | assembles the runtime payload from a finished build |
| `check-payload-closure.sh` | checks the packaged payload is self-contained |
| `mesa-glamor/` | the glamor GL/EGL/GBM stack: pinned upstream Mesa, its patches and build |

## Building

```sh
android/build-gamescope.sh                  # apply the series, configure, build
android/build-gamescope.sh --skip-patches   # build an already-patched tree
android/build-gamescope.sh --setup-only     # configure without building
```

Each patch is applied only if it is not already in the tree (a patch that is
already present is detected and skipped), so re-running the script is safe.

Environment overrides: `NDK` (NDK root), `TERMUXFS` (the bionic prefix to build
against), `BUILD_DIR` (meson build directory, default `build-android`).

All submodules are required — `git submodule update --init --recursive` first.

## Packaging

`android/package-gamescope.sh [YYYYMMDD]` assembles the payload (gamescope,
XWayland, `xkbcomp`, the shared libraries and the Vulkan ICD) and installs it into
the host application's assets as `gamescope-gamenative-<date>.tzst`, together with
the host's userspace-DRM daemon library in that app's `jniLibs`. The app refers to
the payload by that dated name, so a repackaged payload must have its reference
moved with it.

The Vulkan ICD in the payload is built by the separate `gamenative-drm` project,
not from this tree; this script only stages it.

The payload is reproducible: the packager honours `SOURCE_DATE_EPOCH` (a
caller-supplied value, else the tree's commit time) and normalises the archive —
fixed member mtimes, `--sort=name` order, `uid/gid 0` — so identical inputs
rebuild to byte-identical `.tzst` bytes. The dated filename is a name only; it
does not enter the archive.

## Related projects

This tree is only the display server. The pieces it stages but does not build:

| project | what it contributes |
|---|---|
| `gamenative-drm` | the userspace-DRM daemon library, the Vulkan ICD and the LD_PRELOAD socket shim, plus the `gn-dmabuf-test` / `gn-wsi-test` / `gn-xtree-probe` clients in `bin/` |
| `gamenative-xwayland` | the Xwayland binary and its payload, absorbed into this one |

Each sibling is looked up beside this checkout and can be pointed elsewhere with
its env override (`GNDRM_DIR`, `GN_XWAYLAND_DIR`).

The minimal GL/EGL stack (zink + softpipe) that Xwayland's glamor runs on is
built from this tree: `android/mesa-glamor/build-mesa-glamor.sh` patches a
pinned upstream Mesa release and stages it where the packager looks for it
(`GN_MESA_GLAMOR_STAGE`). The packager runs that build itself whenever the stage
is missing, built from another Mesa version, or older than the sources in
`android/mesa-glamor/` — a stage directory that exists is not evidence that it
is current, and the payload's glamor is only as new as that stage. See
`android/mesa-glamor/README.md`.

### Two Mesas: glamor's and the guest's

The glamor Mesa above is Xwayland's: it lives in the payload and renders the X
server's own drawing. It is not the OpenGL library a Windows game gets. That one
is the guest libGL, `usr/lib/libGL.so.1.5.0` (with `libglapi.so.0`) in the app's
`extra_libs.tzst` archive, which the app extracts into every container at launch
and which Wine's winex11 loads (`WINE_X11FORCEGLX=1`) on BOTH display servers,
the in-app X11 server and gamescope/Xwayland: the same file, same bytes. It is
Mesa's xlib GLX emulation on zink (fbconfigs are X visuals, frames reach the X
server through XShmPutImage, no DRI), from the Pipetto xlib/zink fork: branch
`zink-mesa-xlib-pipetto` of GameNative/mesa, and the shipped file reports
`Mesa 24.3.0-devel (git-c1567e9609)`, so it carries that fork's changes up to
that commit and nothing above it. Upstream Mesa deleted the xlib GLX frontend in
26.3 (7055daf6a57), so it cannot be rebuilt from the glamor tarball.

Glamor is optional for a session. Every Vulkan guest presents through the WSI
shim, so an Xwayland without glamor (`XWAYLAND_NO_GLAMOR=1`, software rendering
for the X server's own drawing) still serves the same clients; the app sets that
itself on non-Adreno devices, where the system driver wedges the zink bring-up.
Where glamor's EGL bring-up fails on a device the app did not predict (an abort
in the driver at make-current was seen on an Adreno 750 with a self-built
Turnip), the child dies or stalls before its `-displayfd` write, and A58 retries
the base Xwayland once with `XWAYLAND_NO_GLAMOR=1` instead of failing the session
at the A24 deadline. The log names the retry and which attempt is running.

What differs between the two display servers is therefore never the library but
the X server it asks: Xwayland's default visual is depth 24, the in-app server's
single visual is depth 32, and the emulation reports GLX_BUFFER_SIZE from the
visual depth (GameNative/mesa#58 makes it count the emulated alpha channel, so an
8/8/8/8 format says 32 on both). A guest GL frame always arrives on the X
window's own surface, not on the WSI shim's override surface, which is what A33
has to account for.

Building that libGL (no CI does it; the wrapper package script only repacks the
shipped file): the cross setup of `android/kopper/configure.sh` on GameNative/mesa
branch `zink-kopper-mali-24.3` (NDK 27.3 + a termux aarch64 sysroot) with
`-Dglx=xlib -Dgallium-drivers=zink -Dvulkan-drivers= -Degl=disabled -Dgbm=disabled
-Dplatforms=x11 -Dshared-glapi=enabled -Dglvnd=disabled -Dllvm=disabled
-Dxmlconfig=disabled -Dexpat=disabled -Dzstd=enabled`, `-fno-emulated-tls` in
`c_args`/`cpp_args` (the shipped `libglapi.so.0` exports `_glapi_tls_Context` as
ELF TLS; an emutls libGL fails to dlopen against it). Building a commit from
before Pipetto's "disable dri options query" hack (the shipped c1567e9609 is
one) also needs `idep_xmlconfig` on the `libgl-xlib` meson target, since zink's
driconf calls then need the stub; the branch head does not.
