#!/usr/bin/env python3
"""Point a Termux prefix's pkg-config files at wherever the tree was unpacked.

The prebuilt tree names its on-device path, /data/data/com.termux/files/usr,
in every .pc file. Two other things need fixing for a cross build:

* ${pc_sysrootdir} must go: pkgconf prefixes it with its own prefix, which
  doubles the path.
* The flags must not name the prefix's include root. Older meson turns a
  pkg-config -I into -isystem, and -isystem is searched before the compiler's
  sysroot, so the tree's stdint.h/stdlib.h would shadow the NDK's and libc++
  refuses to compile. The cross file already passes that directory with
  -idirafter, which puts it behind the sysroot. Subdirectories such as
  include/libdrm stay.

Usage: normalize-pc.py <prefix> <path>... (or paths on stdin)
Re-running is safe.
"""

import re
import sys


def normalize(path, prefix, dev, root):
    with open(path, encoding="utf-8", errors="surrogateescape") as handle:
        text = handle.read()

    text = text.replace("${pc_sysrootdir}", "")

    if root:
        # collapse /root/root/... so re-running does not stack roots
        text = re.sub(re.escape(root) + "(?:" + re.escape(root) + ")+", root, text)
        # rewrite the on-device path, leaving an already-rewritten one alone
        text = re.sub("(?<!" + re.escape(root) + ")" + re.escape(dev), prefix, text)

    # does this file's includedir resolve to the prefix root?
    match = re.search(r"^includedir=(.+)$", text, re.M)
    include_root = False
    if match:
        value = match.group(1).strip()
        value = value.replace("${prefix}", prefix).replace("${exec_prefix}", prefix)
        include_root = value.rstrip("/") == prefix + "/include"

    if include_root:
        # only the bare token, never -I${includedir}/libdrm and friends
        text = re.sub(r"-I\$\{includedir\}(?![/\w.-])", "", text)
    text = re.sub(r"\s-I" + re.escape(prefix + "/include") + r"(?![/\w.-])", "", text)

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(text)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    prefix = sys.argv[1].rstrip("/")
    dev = "/data/data/com.termux/files/usr"
    root = prefix[: -len(dev)] if prefix.endswith(dev) else ""

    paths = sys.argv[2:]
    if not paths:
        paths = sys.stdin.read().split("\0")
    for path in paths:
        if path:
            normalize(path, prefix, dev, root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
