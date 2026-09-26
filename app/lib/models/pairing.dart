import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which devices this person set up with: the Audios alone, or with a Band.
enum PairingSetup { audiosAndBand, audiosOnly }

/// One device found while scanning.
class FoundDevice {
  const FoundDevice({required this.id, required this.name, required this.rssi});

  /// The CoreBluetooth identifier. iOS never exposes a device's MAC address to
  /// apps; this identifier is stable for this phone and is what reconnects.
  final String id;
  final String name;
  final int rssi;
}

/// First-launch setup and the Bluetooth link to the Audios and the Band.
///
/// Until the hardware exists there is no Bluetooth spec to match on, so a
/// scan looks for anything advertising a name with "Ordinary" or "Ordi" in it,
/// and reads the standard Battery Service if the device has one. Swap the
/// filter for the real service UUID once the firmware defines it.
class Pairing extends ChangeNotifier {
  static const _prefsKey = 'pairing_v1';

  /// Names a scan accepts, case-insensitively.
  static const nameKeywords = ['ordinary', 'ordi'];

  static final Uuid _batteryService = Uuid.parse('180F');
  static final Uuid _batteryLevel = Uuid.parse('2A19');

  /// Created on first use, so merely building the app (and its tests) never
  /// touches Bluetooth or triggers the permission prompt.
  FlutterReactiveBle? _bleInstance;
  FlutterReactiveBle get _ble => _bleInstance ??= FlutterReactiveBle();

  bool loaded = false;

  /// Set once the person has finished setup, by pairing or by skipping.
  bool done = false;
  PairingSetup setup = PairingSetup.audiosAndBand;

  String? audiosId;
  String? bandId;
  String? audiosName;
  String? bandName;

  /// Live link state, not persisted.
  bool audiosConnected = false;
  bool bandConnected = false;
  int audiosBattery = -1;
  int bandBattery = -1;

  bool get wantsBand => setup == PairingSetup.audiosAndBand;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        done = map['done'] as bool? ?? false;
        setup = map['setup'] == 'audiosOnly'
            ? PairingSetup.audiosOnly
            : PairingSetup.audiosAndBand;
        audiosId = map['audiosId'] as String?;
        bandId = map['bandId'] as String?;
        audiosName = map['audiosName'] as String?;
        bandName = map['bandName'] as String?;
      } catch (_) {
        // A corrupt record just means setup runs again.
      }
    }
    loaded = true;
    notifyListeners();
    unawaited(reconnect());
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'done': done,
        'setup': setup.name,
        'audiosId': ?audiosId,
        'bandId': ?bandId,
        'audiosName': ?audiosName,
        'bandName': ?bandName,
      }),
    );
  }

  void choose(PairingSetup value) {
    setup = value;
    if (!wantsBand) {
      bandId = null;
      bandName = null;
      bandConnected = false;
    }
    notifyListeners();
    _persist();
  }

  void finish() {
    reopened = false;
    done = true;
    notifyListeners();
    _persist();
  }

  /// True while setup has been reopened from Settings, so it can be closed
  /// without going through it again.
  bool reopened = false;

  /// Starts setup again from Settings.
  void restart() {
    reopened = true;
    done = false;
    notifyListeners();
  }

  /// Leaves a reopened setup as it was.
  void close() {
    reopened = false;
    done = true;
    notifyListeners();
  }

  // ------------------------------------------------------------- bluetooth

  /// Bluetooth's state, for telling "Bluetooth is off" or "not allowed" apart
  /// from "nothing found".
  Stream<BleStatus> get status => _ble.statusStream;

  /// Scans for Ordinary devices, emitting the growing list as they appear, and
  /// stops by itself after [timeout].
  Stream<List<FoundDevice>> scan({Duration timeout = const Duration(seconds: 20)}) {
    final found = <String, FoundDevice>{};
    late StreamController<List<FoundDevice>> controller;
    StreamSubscription<DiscoveredDevice>? sub;
    Timer? stop;
    controller = StreamController<List<FoundDevice>>(
      onListen: () {
        sub = _ble.scanForDevices(
          withServices: const [],
          scanMode: ScanMode.lowLatency,
        ).listen(
          (d) {
            final lower = d.name.toLowerCase();
            if (!nameKeywords.any(lower.contains)) return;
            found[d.id] = FoundDevice(id: d.id, name: d.name, rssi: d.rssi);
            controller.add(found.values.toList()
              ..sort((a, b) => b.rssi.compareTo(a.rssi)));
          },
          onError: controller.addError,
        );
        stop = Timer(timeout, () async {
          await sub?.cancel();
          if (!controller.isClosed) await controller.close();
        });
      },
      onCancel: () async {
        stop?.cancel();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  /// The live connection to each device. Closing the subscription is what
  /// disconnects, so these are held for as long as the device is paired.
  final Map<String, StreamSubscription<ConnectionStateUpdate>> _links = {};

  /// Connects and resolves once connected, or throws on failure or timeout.
  Future<void> _link(String id, {required bool band}) {
    final done = Completer<void>();
    _links.remove(id)?.cancel();
    _links[id] = _ble
        .connectToDevice(id: id, connectionTimeout: const Duration(seconds: 15))
        .listen((update) async {
      final up = update.connectionState == DeviceConnectionState.connected;
      if (band) {
        bandConnected = up;
      } else {
        audiosConnected = up;
      }
      if (up) {
        final battery = await _readBattery(id);
        if (band) {
          bandBattery = battery;
        } else {
          audiosBattery = battery;
        }
        if (!done.isCompleted) done.complete();
      } else if (update.connectionState == DeviceConnectionState.disconnected &&
          !done.isCompleted) {
        done.completeError(update.failure?.message ?? 'Could not connect.');
      }
      notifyListeners();
    }, onError: (Object error) {
      if (!done.isCompleted) done.completeError(error);
    });
    return done.future.timeout(const Duration(seconds: 20));
  }

  /// Connects to a found device and remembers it as the Audios or the Band.
  Future<void> connect(FoundDevice found, {required bool band}) async {
    await _link(found.id, band: band);
    if (band) {
      bandId = found.id;
      bandName = found.name;
    } else {
      audiosId = found.id;
      audiosName = found.name;
    }
    notifyListeners();
    await _persist();
  }

  /// Reconnects to whatever was paired before, quietly, at launch.
  Future<void> reconnect() async {
    for (final (id, band) in [(audiosId, false), (bandId, true)]) {
      if (id == null) continue;
      try {
        await _link(id, band: band);
      } catch (_) {
        // Off, out of range, or no Bluetooth: it shows as not connected.
      }
    }
  }

  /// The standard Battery Level characteristic, or -1 if the device has none.
  Future<int> _readBattery(String id) async {
    try {
      await _ble.discoverAllServices(id);
      final value = await _ble.readCharacteristic(QualifiedCharacteristic(
        serviceId: _batteryService,
        characteristicId: _batteryLevel,
        deviceId: id,
      ));
      if (value.isNotEmpty) return value.first.clamp(0, 100);
    } catch (_) {}
    return -1;
  }

  /// Forgets a device so it can be set up again.
  Future<void> forget({required bool band}) async {
    final id = band ? bandId : audiosId;
    if (id != null) await _links.remove(id)?.cancel();
    if (band) {
      bandId = null;
      bandName = null;
      bandConnected = false;
      bandBattery = -1;
    } else {
      audiosId = null;
      audiosName = null;
      audiosConnected = false;
      audiosBattery = -1;
    }
    notifyListeners();
    await _persist();
  }

  @override
  void dispose() {
    for (final link in _links.values) {
      link.cancel();
    }
    super.dispose();
  }
}
