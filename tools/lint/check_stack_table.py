#!/usr/bin/env python3
"""
CTO Rule (blueprint §7.2): every FreeRTOS task declares its stack size in a
single central table, checked at build time. Prevents the undersized-stack
heap corruption that cost time on Toad's shipped firmware.

This check parses every xTaskCreate*(...) call in firmware/ and confirms the
task's name string also appears as a row in firmware/task_stacks.md.
The real high-water-mark measurement still has to happen on real hardware
(§20) — this only catches "a task exists that nobody put in the table."
"""
import re
import subprocess
import sys
from pathlib import Path

TABLE_PATH = Path("firmware/task_stacks.md")

TASK_CREATE_RE = re.compile(
    r'xTaskCreate\w*\s*\([^,]+,\s*"([^"]+)"'
)


def tracked_firmware_sources():
    out = subprocess.run(
        ["git", "ls-files", "firmware"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [f for f in out.splitlines() if f.endswith((".c", ".cpp", ".cc"))]


def main():
    files = tracked_firmware_sources()
    if not files:
        print("note: no firmware sources tracked yet — nothing to check")
        sys.exit(0)

    if not TABLE_PATH.exists():
        print(f"FAIL: {TABLE_PATH} does not exist, but firmware sources do. "
              f"Create the central stack-size table before adding tasks.")
        sys.exit(1)

    table_text = TABLE_PATH.read_text(encoding="utf-8")

    found_tasks = {}
    for path in files:
        text = Path(path).read_text(encoding="utf-8", errors="ignore")
        for m in TASK_CREATE_RE.finditer(text):
            found_tasks.setdefault(m.group(1), path)

    fail = False
    for name, path in found_tasks.items():
        if name not in table_text:
            print(f"FAIL: task \"{name}\" created in {path} has no row in {TABLE_PATH}")
            fail = True

    if not fail:
        print(f"OK: {len(found_tasks)} task(s) all present in {TABLE_PATH}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
