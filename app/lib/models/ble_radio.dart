import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:ordi_audio/ordi_audio.dart' show OrdiAudio;

/// The Bluetooth headsets the phone itself is connected to, by name; the
/// battery of the one asked about (-1 if it reports none); and, for
/// diagnostics, what else the phone holds a low-energy link to.
typedef LinkedAudio = ({List<String> names, int battery, List<String> gatt});

/// One device found while scanning.
class FoundDevice {
  const FoundDevice({
    required this.id,
    required this.name,
    required this.rssi,
    this.services = const [],
    this.connectable = true,
  });

  /// The CoreBluetooth identifier. iOS never exposes a device's MAC address to
  /// apps; this identifier is stable for this phone and is what reconnects.
  final String id;
  final String name;
  final int rssi;

  /// The service ids it advertises, for diagnostics.
  final List<String> services;
  final bool connectable;
}

/// The phone's Bluetooth, reduced to what pairing needs. The app talks to the
/// real radio through [ReactiveRadio]; tests stand in a fake, since no test
/// can reach a Bluetooth chip.
abstract class BleRadio {
  /// Bluetooth's state, for telling "Bluetooth is off" or "not allowed" apart
  /// from "nothing found".
  Stream<BleStatus> get status;

  /// Every named device in range, repeatedly, until cancelled.
  Stream<FoundDevice> scan();

  /// Opens a connection and reports it: true once connected, false when it
  /// drops or cannot be made. With no [timeout] the attempt stays open until
  /// the device comes into range, which is what reconnects it by itself.
  /// Cancelling the subscription disconnects.
  Stream<bool> link(String id, {Duration? timeout});

  /// Every characteristic the connected device offers, as
  /// "service/characteristic:properties", for diagnostics.
  Future<List<String>> describe(String id);

  /// The standard Battery Level, 0..100, or null if the device has none.
  Future<int?> battery(String id);

  /// The battery level each time the device announces a change.
  Stream<int> batteryUpdates(String id);

  /// Headsets connected by the phone rather than by the app. Audio glasses
  /// are this kind of device: paired in the phone's Bluetooth settings, and
  /// connected by the phone whenever they are switched on. An app cannot
  /// open or close that connection, only see it.
  Future<LinkedAudio> linkedAudio({String? batteryFor});

  /// Starts looking for headsets nearby that are not paired with the phone
  /// yet. False where an app is not allowed to (iOS: pairing a headset is
  /// only possible in Settings).
  Future<bool> searchHeadsets();

  /// Headsets seen since [searchHeadsets] began. `id` is the address to pair.
  Future<List<FoundDevice>> headsetsFound();

  /// Pairs the phone with a headset; the phone then connects it by itself.
  Future<bool> pairHeadset(String address);

  /// Everything broadcasting within arm's reach, named or not, as plain
  /// facts. Only for working out what an unfamiliar device offers.
  Stream<Map<String, Object>> survey();
}

class ReactiveRadio implements BleRadio {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  static final Uuid _batteryService = Uuid.parse('180F');
  static final Uuid _batteryLevel = Uuid.parse('2A19');

  QualifiedCharacteristic _battery(String id) => QualifiedCharacteristic(
        serviceId: _batteryService,
        characteristicId: _batteryLevel,
        deviceId: id,
      );

  @override
  Stream<BleStatus> get status => _ble.statusStream;

  @override
  Stream<FoundDevice> scan() => _ble
      .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
      .where((d) => d.name.isNotEmpty)
      .map((d) => FoundDevice(
            id: d.id,
            name: d.name,
            rssi: d.rssi,
            services: [for (final u in d.serviceUuids) '$u'],
            connectable: d.connectable != Connectable.unavailable,
          ));

  @override
  Stream<bool> link(String id, {Duration? timeout}) => _ble
      .connectToDevice(id: id, connectionTimeout: timeout)
      .where((u) =>
          u.connectionState == DeviceConnectionState.connected ||
          u.connectionState == DeviceConnectionState.disconnected)
      .map((u) => u.connectionState == DeviceConnectionState.connected);

  @override
  Future<List<String>> describe(String id) async {
    await _ble.discoverAllServices(id);
    final services = await _ble.getDiscoveredServices(id);
    return [
      for (final s in services)
        for (final c in s.characteristics)
          '${s.id}/${c.id}:'
              '${c.isReadable ? 'r' : ''}'
              '${c.isWritableWithResponse || c.isWritableWithoutResponse ? 'w' : ''}'
              '${c.isNotifiable || c.isIndicatable ? 'n' : ''}',
    ];
  }

  @override
  Future<int?> battery(String id) async {
    try {
      final value = await _ble.readCharacteristic(_battery(id));
      if (value.isNotEmpty) return value.first.clamp(0, 100);
    } catch (_) {
      // No battery service, or the link dropped mid-read.
    }
    return null;
  }

  @override
  Future<LinkedAudio> linkedAudio({String? batteryFor}) =>
      OrdiAudio.bluetoothAudio(batteryFor: batteryFor);

  @override
  Future<bool> searchHeadsets() => OrdiAudio.bluetoothSearch();

  @override
  Future<List<FoundDevice>> headsetsFound() async => [
        for (final d in await OrdiAudio.bluetoothFound())
          FoundDevice(id: d.address, name: d.name, rssi: d.rssi),
      ];

  @override
  Future<bool> pairHeadset(String address) => OrdiAudio.bluetoothPair(address);

  @override
  Stream<Map<String, Object>> survey() => _ble
      .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
      .where((d) => d.rssi >= -62)
      .map((d) {
        final maker = d.manufacturerData;
        return {
          'key': d.id,
          'name': d.name,
          'rssi': d.rssi,
          'services': [for (final u in d.serviceUuids) '$u'],
          // The company identifier, then how much follows it.
          if (maker.length >= 2)
            'maker':
                '${maker[1].toRadixString(16).padLeft(2, '0')}${maker[0].toRadixString(16).padLeft(2, '0')}+${maker.length - 2}',
          'connectable': d.connectable.name,
        };
      });

  @override
  Stream<int> batteryUpdates(String id) => _ble
      .subscribeToCharacteristic(_battery(id))
      .where((v) => v.isNotEmpty)
      .map((v) => v.first.clamp(0, 100));
}
