# mesa-glamor

The GL/EGL/GBM stack Xwayland's glamor runs on inside the payload: upstream
Mesa, pinned to one release, with a short patch series on top. gallium zink +
softpipe only, no LLVM, glvnd EGL vendor on the GBM platform.

| path | what |
|---|---|
| `fetch-mesa.sh` | downloads the pinned release tarball, checks its sha256, extracts it, applies `patches/` |
| `build-mesa-glamor.sh` | fetches, configures and builds, installs into the stage |
| `cross.txt.in` | meson cross file template (filled in by the build script) |
| `overlay/` | header stubs (cutils, log, glvnd ABI) and pkg-config files for the cross build |
| `patches/` | the Mesa source changes, `git format-patch` output, applied with `patch -p1` |

```sh
android/mesa-glamor/build-mesa-glamor.sh
GN_MESA_GLAMOR_STAGE=$PWD/build-android-mesa-glamor/stage android/package-gamescope.sh
```

The stage defaults to `build-android-mesa-glamor/stage`, which is also where
`package-gamescope.sh` looks — and it builds the stage itself when it is missing,
built from another Mesa version, or older than the sources here, so the manual
run is only needed to compile ahead of a pack. Linux or macOS; needs the NDK
(`NDK`), the termux prefix (`TERMUXFS`), bison and flex in `PATH`, and `python3`
with venv support — meson >= 1.4 plus mako, PyYAML and packaging are provisioned
into `venv/` in the work dir. The CI workflow builds it and uploads the stage as
the `mesa-glamor-stage-<sha>` artifact.

## Patches

- `0001` gbm, loader: accept the gndrm socket fd as a render node, pick zink
  for it, find the GBM backend next to libgbm, build dril for a GBM-only build.
- `0002` zink: name command buffers only when tracing or capturing. gn-vkshim
  passes `vkSetDebugUtilsObjectNameEXT` to Turnip with its own wrapper handles,
  which faults. Drop it once the shim unwraps the handle.

## Moving to a new Mesa release

Set `MESA_VERSION` and `MESA_SHA256` in `fetch-mesa.sh`, rebase the patches
(apply them to the tag in a Mesa checkout, fix, `git format-patch`), build, and
check the stage file list: the libgallium name follows the version and
`package-gamescope.sh` reads it from the stage.
