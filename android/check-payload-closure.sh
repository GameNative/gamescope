#!/usr/bin/env bash
# check-payload-closure.sh — prove a gamescope payload is self-contained.
#
# For every ELF shipped in the asset (bin/, lib/, lib/dri/), collect
#   * every DT_NEEDED SONAME, and
#   * every dlopen'd library name visible as a string,
# and require each to resolve EITHER inside the payload (a file of that exact
# name under lib/ or lib/dri/) OR against the bionic/NDK system allowlist
# below. Also parses the shipped glvnd/vulkan json manifests' library_path.
#
# This is the acceptance test for the GL/EGL/glamor library set: a name that
# resolves only on the build host (a termux-prefix path) shows up here as
# UNRESOLVED, exactly the class of bug ("libEGL.so.1 not found") this guards.
#
# Usage: check-payload-closure.sh [asset.tzst]     (default: the newest gamescope-gamenative-*.tzst)
set -euo pipefail

GN_DIR="${GN_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/GameNative}"
ASSET="${1:-$(ls -t "$GN_DIR"/app/src/main/assets/gamescope-gamenative-*.tzst 2>/dev/null | head -1)}"
[ -f "$ASSET" ] || { echo "missing asset: $ASSET" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar --zstd -xf "$ASSET" -C "$WORK"

# Names bionic/NDK genuinely provide on every device (loader + libc family +
# the Android platform GL entry points we do NOT own). Anything else must be
# in the payload.
SYSTEM_RE='^(libc|libm|libdl|liblog|libandroid|libz|libsync|libstdc\+\+|ld-android|libEGL|libGLESv1_CM|libGLESv2|libGLESv3|libvulkan)\.so$'

fail=0
declare -A present
for p in "$WORK"/lib/*.so* "$WORK"/lib/dri/*; do
    [ -e "$p" ] || continue
    present["$(basename "$p")"]=1
done

# dlopen probes that are NOT part of the shipped runtime set: loaded only on a
# code branch that is not exercised in a Gamescope session (desktop-GL/X11
# fallbacks of libepoxy and the ICD shim's X11/adrenotools guest hooks). They
# are reported, never counted as failures, but they are never silently hidden.
OPTIONAL_RE='^(libadrenotools\.so|libX11\.so\.6|libxcb\.so\.1|libGL\.so\.1|libGLX\.so\.1|libOpenGL\.so\.0|librenderdoc\.so)$'

check_name() { # check_name <name> <needed-by> <kind>
    local name="$1" by="$2" kind="$3"
    if [ -n "${present[$name]:-}" ]; then
        printf '  OK         %-34s %s (%s)\n' "$name" "$kind" "$by"
        return
    fi
    if [[ "$name" =~ $SYSTEM_RE ]]; then
        printf '  system     %-34s %s (%s)\n' "$name" "$kind" "$by"
        return
    fi
    if [[ "$name" =~ $OPTIONAL_RE ]]; then
        printf '  optional   %-34s %s (%s)\n' "$name" "$kind" "$by"
        return
    fi
    printf '  UNRESOLVED %-34s %s (%s)\n' "$name" "$kind" "$by"
    fail=1
}

echo "=== asset"
printf '  %s  (%s)\n' "$ASSET" "$(du -h "$ASSET" | cut -f1)"

echo
echo "=== DT_NEEDED closure (every shipped ELF)"
while IFS= read -r elf; do
    while read -r name; do
        [ -n "$name" ] || continue
        check_name "$name" "${elf#$WORK/}" "DT_NEEDED"
    done < <(readelf -d "$elf" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
done < <(find "$WORK"/bin "$WORK"/lib -type f 2>/dev/null | sort)

echo
echo "=== dlopen'd SONAMEs (string scan of every shipped ELF)"
# Mesa/X drivers dlopen by bare name; strings is how we see them statically.
# An ELF's own SONAME is dropped (it is not a load target).
while IFS= read -r elf; do
    self="$(readelf -d "$elf" 2>/dev/null | sed -nE 's/.*\(SONAME\).*\[(.*)\]/\1/p')"
    while read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$self" ] && continue
        check_name "$name" "${elf#$WORK/}" "dlopen"
    done < <(strings -a "$elf" 2>/dev/null \
             | grep -oE '\blib[A-Za-z0-9_+.-]+\.so(\.[0-9]+){0,3}\b' | sort -u)
done < <(find "$WORK"/bin "$WORK"/lib -type f 2>/dev/null | sort)

echo
echo "=== shipped manifests (library_path must resolve)"
while IFS= read -r j; do
    lp="$(grep -oE '"library_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')"
    [ -n "$lp" ] || continue
    check_name "$lp" "${j#$WORK/}" "json"
done < <(find "$WORK/share" -name '*.json' 2>/dev/null | sort)

echo
echo "=== 16 KB page alignment (every shipped ELF)"
# Android 15+ devices use 16 KB pages; a library aligned below that cannot be
# mapped. Our objects are linked with -Wl,-z,max-page-size=16384, the libraries
# staged from the termux prefix are not necessarily.
below=0
while IFS= read -r elf; do
    [ "$(head -c4 "$elf" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
    a=$(LC_ALL=C readelf -lW "$elf" 2>/dev/null \
        | awk '$1=="LOAD"{v=strtonum($NF); if(v<m||m==0)m=v} END{print m+0}')
    if [ "$a" -lt 16384 ]; then
        printf '  BELOW-16K  %-40s LOAD p_align=0x%x\n' "${elf#$WORK/}" "$a"
        below=1
    fi
done < <(find "$WORK"/bin "$WORK"/lib -type f 2>/dev/null | sort)
if [ "$below" -eq 0 ]; then
    echo "  every shipped ELF has LOAD p_align >= 0x4000 (16 KB)"
else
    echo "  FAIL: a 16 KB-page device cannot load the libraries above"
    fail=1
fi

echo
echo "=== required GL/EGL artefacts"
for f in lib/libEGL.so.1 lib/libEGL_mesa.so.0 lib/libgallium-25.0.0-devel.so \
         lib/libgbm.so.1 lib/libglapi.so.0 lib/libvulkan.so.1 \
         lib/gbm/dri_gbm.so lib/dri/zink_dri.so lib/dri/swrast_dri.so \
         lib/dri/kms_swrast_dri.so lib/dri/libdril_dri.so \
         share/glvnd/egl_vendor.d/50_mesa.json; do
    if [ -e "$WORK/$f" ]; then echo "  present   $f"; else echo "  MISSING   $f"; fail=1; fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: CLEAN — every DT_NEEDED, every non-optional dlopen'd SONAME and"
    echo "        every manifest library_path resolves inside the payload."
else
    echo "RESULT: FAIL — unresolved names above (see UNRESOLVED lines)."
fi
exit "$fail"
