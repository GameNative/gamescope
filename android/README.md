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
| `mesa` | the staged minimal GL/EGL (zink + softpipe) carried under `lib/` |

Each sibling is looked up beside this checkout and can be pointed elsewhere with
its env override (`GNDRM_DIR`, `GN_XWAYLAND_DIR`, `GN_MESA_GLAMOR_STAGE`).
