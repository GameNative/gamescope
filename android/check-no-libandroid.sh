#!/usr/bin/env bash
# check-no-libandroid.sh — refuse any shipped ELF that links libandroid.so.
#
# libandroid.so is the NDK's app-facing platform interface (ANativeWindow,
# AHardwareBuffer). A file that links it can only be loaded in a process whose
# linker namespace carries the NDK stub, which is not this payload's contract:
# every file here resolves against bionic's core (libc/libm/libdl/liblog/libz/
# libsync/ld-android) or against lib/. A dlopen of it from an app library is
# legitimate and is not what this checks; only the link-time dependency is.
#
# A stale libgndrm_shim.so once shipped a NEEDED on libandroid.so and nothing in
# the payload showed it, which is why this is a gate over the whole tree rather
# than a property of the files we build here.
#
# Usage: check-no-libandroid.sh <dir> [dir ...]
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <dir> [dir ...]" >&2; exit 2; }

fail=0
scanned=0
for root in "$@"; do
    [ -d "$root" ] || { echo "missing directory: $root" >&2; exit 2; }
    while IFS= read -r f; do
        [ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
        scanned=$((scanned + 1))
        if readelf -d "$f" 2>/dev/null | grep -q 'NEEDED.*\[libandroid\.so\]'; then
            echo "  NEEDS libandroid.so: ${f#"$root"/}" >&2
            fail=1
        fi
    done < <(find "$root" -type f)
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: a shipped ELF links libandroid.so — build it against bionic's core" >&2
    echo "      libraries instead (the shim's invariant is NEEDED = libc.so libdl.so)" >&2
    exit 1
fi
echo "check-no-libandroid: $scanned ELF(s), none NEEDs libandroid.so"
