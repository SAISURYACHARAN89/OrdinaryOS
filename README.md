# OrdinaryOS

Monorepo for the Ordinary Band: firmware, the Flutter app, the cloud backend,
and the shared Ordinary Link protocol. Phase 1 scope only (Band, no display,
no Glasses) — see the `OrdinaryOS CTO Blueprint v3.1` for the full spec.

The Band PCB isn't built yet. Until it arrives, firmware work happens against
a generic ESP32-WROOM-32 dev board (same silicon family) so nothing here is
blocked on hardware. See `docs/bringup-plan.md`.

## Layout

```
firmware/    OrdinaryOS runtime — ESP-IDF, C. Managers, Link Manager, OTA.
app/         Flutter app. UI / presentation / domain / device / sync / credits / ai / data layers.
backend/     Azure services — profile, credit-service, ai-gateway, sync-service.
protocol/    Ordinary Link — the shared frame format + CBOR schema, consumed by both firmware and app.
docs/        Working docs for this repo (not the blueprint itself).
tools/lint/  The three CI checks below.
```

## Decisions already locked (do not re-open without discussion)

- **Connectivity**: standalone-capable, tethered-optimised. Default to the
  phone's data path; the Band's own SIM/LTE is the fallback when the phone
  is absent.
- **Audio output**: Tricher-bundled earpiece only for v1. No generic
  Bluetooth earbud support — don't build compatibility flows for one.
- **Flash**: 16 MB on the Band (matches Toad's ESP32-WROOM-32E-N16 part).
- **Device security (eFuses)**: not yet decided. Must be settled before any
  production batch — treat as open, don't assume either default.
- **Certification (WPC/TEC/BIS)**: not engaged yet, intentionally deferred.
  The A7672S module is already India-licensed at the module level; full
  device-level certification is a separate, still-open question.

## CTO rules enforced in CI

1. No source file over 800 lines (`tools/lint/check_file_length.sh`).
2. No device-model name as a string literal outside `app/lib/device_assets.dart`
   (`tools/lint/check_device_literals.py`) — the app branches on declared
   capabilities, never on device identity.
3. Every FreeRTOS task has a row in `firmware/task_stacks.md`
   (`tools/lint/check_stack_table.py`).

Run all three locally before pushing:

```bash
bash tools/lint/check_file_length.sh
python3 tools/lint/check_device_literals.py
python3 tools/lint/check_stack_table.py
```
