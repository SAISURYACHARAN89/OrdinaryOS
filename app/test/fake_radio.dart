import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' show BleStatus;
import 'package:ordi/models/ble_radio.dart';

/// The phone's Bluetooth, as a test drives it.
class FakeRadio implements BleRadio {
  FakeRadio({this.nearby = const [], this.answers = false});

  /// What a scan turns up.
  final List<FoundDevice> nearby;

  /// Whether a device connects by itself the moment it is dialled.
  final bool answers;

  /// Every dial, in order: the device, and how long it was willing to wait.
  final List<({String id, Duration? timeout})> dials = [];
  final Map<String, StreamController<bool>> _open = {};

  /// The battery level a read returns; null for a device with no battery
  /// service.
  int? level = 76;
  int reads = 0;
  final StreamController<int> announced = StreamController<int>.broadcast();

  List<String> offered = const ['180f/2a19:rn'];

  /// The device connects (true) or drops (false).
  void say(String id, bool up) => _open[id]?.add(up);

  /// Whether anything is still holding a connection open to [id].
  bool holding(String id) => _open[id]?.hasListener ?? false;

  @override
  Stream<BleStatus> get status => Stream.value(BleStatus.ready);

  @override
  Stream<FoundDevice> scan() {
    final controller = StreamController<FoundDevice>();
    nearby.forEach(controller.add);
    return controller.stream;
  }

  @override
  Stream<bool> link(String id, {Duration? timeout}) {
    dials.add((id: id, timeout: timeout));
    final controller = _open[id] = StreamController<bool>();
    if (answers) controller.add(true);
    return controller.stream;
  }

  @override
  Future<List<String>> describe(String id) async => offered;

  @override
  Future<int?> battery(String id) async {
    reads += 1;
    return level;
  }

  @override
  Stream<int> batteryUpdates(String id) => announced.stream;

  /// Headsets the phone itself is connected to, and the battery it can read.
  List<String> headsets = [];
  int headsetBattery = -1;
  List<String> gatt = [];
  final List<String?> batteryAskedFor = [];

  /// Headsets nearby that the phone is not paired with (Android).
  List<FoundDevice> unpaired = [];
  int searches = 0;
  final List<String> pairedWith = [];

  /// What pairing does: whether it works, and what the phone then connects.
  bool pairs = true;
  List<String> connectsAfterPairing = [];

  @override
  Future<bool> searchHeadsets() async {
    searches += 1;
    return true;
  }

  @override
  Future<List<FoundDevice>> headsetsFound() async => [...unpaired];

  @override
  Future<bool> pairHeadset(String address) async {
    pairedWith.add(address);
    if (pairs) headsets = [...headsets, ...connectsAfterPairing];
    return pairs;
  }

  List<Map<String, Object>> broadcasting = [];
  int surveys = 0;

  @override
  Stream<Map<String, Object>> survey() {
    surveys += 1;
    return Stream.fromIterable(broadcasting);
  }

  @override
  Future<LinkedAudio> linkedAudio({String? batteryFor}) async {
    batteryAskedFor.add(batteryFor);
    return (names: [...headsets], battery: batteryFor == null ? -1 : headsetBattery, gatt: [...gatt]);
  }
}
