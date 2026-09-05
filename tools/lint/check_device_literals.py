#!/usr/bin/env python3
"""
CTO Rule (blueprint §5.2 anti-rewrite rule, §18.2, §24.3):
the app must never branch on a device model name as a string literal.
It branches on capabilities declared at the §6.4 handshake instead.

This check fails the build if a known device-model string appears anywhere
in the Flutter app's Dart source, outside the one file allowed to name them
(the asset map: which icon/label to show for a declared device class).

Update DEVICE_LITERALS as real device classes are added (see the twin
"class" field in blueprint §8.2, e.g. "band.v1", "tog.v1").
"""
import re
import subprocess
import sys

ALLOWED_FILE = "app/lib/device_assets.dart"

DEVICE_LITERALS = [
    r"band\.v1",
    r"tog\.v1",
    r"ORD-BAND",
    r"\bBand\b",
    r"\bGlasses\b",
    r"\bTOG\b",
]

BANNED_RE = re.compile("|".join(DEVICE_LITERALS))


def tracked_dart_files():
    out = subprocess.run(
        ["git", "ls-files", "app/**/*.dart"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [f for f in out.splitlines() if f]


def main():
    fail = False
    for path in tracked_dart_files():
        if path == ALLOWED_FILE:
            continue
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for lineno, line in enumerate(fh, start=1):
                if BANNED_RE.search(line):
                    print(f"FAIL: {path}:{lineno}: device-model literal outside {ALLOWED_FILE}")
                    print(f"    {line.strip()}")
                    fail = True

    if not fail:
        print(f"OK: no device-model literals outside {ALLOWED_FILE}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
