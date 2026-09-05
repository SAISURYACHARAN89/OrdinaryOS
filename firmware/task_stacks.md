# FreeRTOS task stack table

Central, version-controlled record of every task's declared stack size.
Blueprint §7.2: checked at build time (via `tools/lint/check_stack_table.py`)
so a task can never be added without a row here. The high-water-mark number
is filled in once it's actually measured on real hardware (§20) — until then
leave it blank rather than guessing.

| Task name | Declared stack (bytes) | Measured high-water-mark | Owner manager | Notes |
|---|---|---|---|---|
| _(none yet)_ | | | | |
