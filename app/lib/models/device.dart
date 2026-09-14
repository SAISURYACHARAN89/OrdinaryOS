import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/device_icons.dart';
import '../ui/time_format.dart';

/// The live state of one Ordinary device.
class DeviceState {
  const DeviceState({
    required this.device,
    required this.connected,
    required this.battery,
  });

  final OrdinaryDevice device;
  final bool connected;

  /// 0..100.
  final int battery;

  String get batteryLabel => '$battery%';
}

/// Where device state comes from.
///
/// **Mock for now, and deliberately shaped like the real thing.** Neither the
/// glasses nor the Band exist yet, so these are invented numbers — but they
/// arrive through the same notifier the BLE layer will publish to, so swapping
/// in real hardware means replacing this class, not rewriting the screens that
/// read it.
class Devices extends ChangeNotifier {
  Devices();

  static const _selectedPrefsKey = 'selected_device_v1';
  static const _lastSyncedPrefsKey = 'band_last_synced_v1';

  DeviceState audio = const DeviceState(
    device: OrdinaryDevice.audio,
    connected: true,
    battery: 82,
  );

  DeviceState band = const DeviceState(
    device: OrdinaryDevice.band,
    connected: true,
    battery: 22,
  );

  /// Which device the controls below the cards act on.
  ///
  /// Persisted — battery and connection state below are mock telemetry that
  /// should look freshly read each launch, but which device you last had
  /// selected is a real preference, not something to reset underneath you.
  OrdinaryDevice selected = OrdinaryDevice.band;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_selectedPrefsKey);
    for (final device in OrdinaryDevice.values) {
      if (device.name == saved && device != selected) {
        selected = device;
        notifyListeners();
      }
    }
    // Unlike the mock battery/connection numbers above, this is a real fact
    // worth remembering across launches — "have I synced since I last added
    // a note" doesn't reset just because the app restarted.
    final savedSync = prefs.getString(_lastSyncedPrefsKey);
    final parsed = savedSync == null ? null : DateTime.tryParse(savedSync);
    if (parsed != null) {
      lastSynced = parsed;
      notifyListeners();
    }
  }

  void select(OrdinaryDevice device) {
    if (selected == device) return;
    selected = device;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_selectedPrefsKey, device.name));
  }

  DeviceState stateFor(OrdinaryDevice device) =>
      device == OrdinaryDevice.audio ? audio : band;

  // ------------------------------------------------------------------ sync

  bool syncing = false;
  DateTime? lastSynced;

  /// Pushes study notes and contacts to the Band.
  ///
  /// Fake until there is something to sync to. Kept async and stateful anyway
  /// so the UI is built against the real shape — a sync that takes time and
  /// can fail — rather than an instant one that will need reworking.
  Future<void> sync() async {
    if (syncing) return;
    syncing = true;
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 1600));

    syncing = false;
    lastSynced = DateTime.now();
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncedPrefsKey, lastSynced!.toIso8601String());
  }

  String get syncLabel {
    if (syncing) return 'Syncing to Band…';
    final at = lastSynced;
    if (at == null) return 'Not synced yet';
    final mins = DateTime.now().difference(at).inMinutes;
    if (mins < 1) return 'Synced just now';
    if (mins < 60) return 'Synced ${mins}m ago';
    if (mins < 24 * 60) return 'Synced ${mins ~/ 60}h ago';
    return 'Synced ${dayTimeLabel(at)}';
  }
}
