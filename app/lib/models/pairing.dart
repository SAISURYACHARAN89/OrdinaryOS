import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session.dart';
import 'ble_radio.dart';

export 'ble_radio.dart' show FoundDevice;

/// Which devices this person set up with: the Audios alone, or with a Band.
enum PairingSetup { audiosAndBand, audiosOnly }

/// First-launch setup and the Bluetooth link to the Audios and the Band.
///
/// The Audios are real, and are a Bluetooth headset called "SM03". A headset
/// is paired once in the phone's own Bluetooth settings and after that the
/// phone connects it whenever it is switched on; an app cannot make that
/// connection, only see it. So setup looks for an SM03 among the headsets
/// the phone is connected to, remembers it, and from then on shows whether it
/// is connected right now, with its battery where the headset reports one.
/// (A low-energy device with that name is found by scanning and connected
/// directly, should a later model work that way.) The Band has no hardware
/// yet, so it is still a stand-in.
class Pairing extends ChangeNotifier {
  Pairing({BleRadio? radio}) : _radioInstance = radio ?? radioForTesting;

  static const _prefsKey = 'pairing_v1';

  /// Whether a device with this name is a pair of Audios. The model is SM03;
  /// "SMO3", with the letter O, is accepted too, since it is easily mistyped
  /// in firmware as well as by people.
  static bool isAudios(String name) {
    final lower = name.toLowerCase();
    return lower.contains('sm03') || lower.contains('smo3');
  }

  /// Whether a device with this name is a Band.
  static bool isBand(String name) {
    final lower = name.toLowerCase();
    return lower.contains('band') && lower.contains('ordi');
  }

  /// A stand-in shown in every Band scan until the Band ships, so the whole
  /// pairing flow can be walked through. Connecting to it touches no
  /// Bluetooth at all.
  static const demoBand =
      FoundDevice(id: 'demo:band', name: 'Ordinary Band', rssi: -55);
  static bool isDemo(String? id) => id != null && id.startsWith('demo:');

  /// How Audios connected by the phone itself are remembered: by name, since
  /// the app never holds that connection and is given no identifier for it.
  static const _phonePrefix = 'audio:';
  static bool isPhoneLinked(String? id) =>
      id != null && id.startsWith(_phonePrefix);

  /// A headset found nearby that the phone is not paired with yet (Android
  /// only). Pairing it turns it into a phone-linked one.
  static const _unpairedPrefix = 'classic:';
  static bool isUnpairedHeadset(String? id) =>
      id != null && id.startsWith(_unpairedPrefix);

  /// Stands in for the phone's Bluetooth in tests.
  @visibleForTesting
  static BleRadio? radioForTesting;

  /// Created on first use, so merely building the app (and its tests) never
  /// touches Bluetooth or triggers the permission prompt.
  BleRadio? _radioInstance;
  BleRadio get _radio => _radioInstance ??= ReactiveRadio();

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

  /// Whether the Band is offered beside the Audios. It has no hardware yet,
  /// so it connects as a stand-in; a build can hide it entirely with
  /// `--dart-define=ORDI_BAND=false`, and then setup is the Audios alone,
  /// whatever was chosen before.
  static bool bandAvailable =
      const bool.fromEnvironment('ORDI_BAND', defaultValue: true);

  bool get wantsBand =>
      bandAvailable && setup == PairingSetup.audiosAndBand;

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
    // Before the Audios were real, setup "paired" a stand-in. It was never a
    // device: forget it, so the card asks to pair instead of claiming a
    // connection that does not exist.
    if (audiosId != null && isDemo(audiosId)) {
      audiosId = null;
      audiosName = null;
      unawaited(_persist());
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
    notifyListeners();
    // Also closes the Bluetooth link, which otherwise stayed open and kept
    // marking a Band nobody set up as connected.
    if (!wantsBand && bandId != null) {
      forget(band: true);
    } else {
      _persist();
    }
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
  Stream<BleStatus> get status => _radio.status;

  /// Scans for the Audios (or the Band), emitting the growing list as they
  /// appear, and stops by itself after [timeout].
  Stream<List<FoundDevice>> scan({
    bool band = false,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final found = <String, FoundDevice>{};
    late StreamController<List<FoundDevice>> controller;
    StreamSubscription<FoundDevice>? sub;
    Timer? stop;
    Timer? look;
    var nearby = 0;
    var headsets = const <String>[];

    /// How directly a find leads to working Audios: already connected by the
    /// phone, then a headset the phone can pair, then a low-energy device.
    int rank(FoundDevice d) =>
        isPhoneLinked(d.id) ? 0 : (isUnpairedHeadset(d.id) ? 1 : 2);

    void emit() {
      if (controller.isClosed) return;
      // The same pair seen more than one way is one pair: keep the best.
      final best = <String, FoundDevice>{};
      for (final d in found.values) {
        final key = d.name.toLowerCase();
        final held = best[key];
        if (held == null || rank(d) < rank(held)) best[key] = d;
      }
      controller.add(best.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi)));
    }

    /// Audios the phone is already connected to as a headset.
    Future<void> lookAtPhone() async {
      final linked = await _radio.linkedAudio();
      headsets = linked.names;
      var added = false;
      for (final name in linked.names) {
        if (!isAudios(name)) continue;
        final id = '$_phonePrefix$name';
        if (!found.containsKey(id)) {
          OrdiBackend.diag('audio-found', name);
          added = true;
        }
        found[id] = FoundDevice(id: id, name: name, rssi: -40);
      }
      // And, where the phone lets an app look, Audios not paired with it yet.
      for (final d in await _radio.headsetsFound()) {
        if (!isAudios(d.name)) continue;
        final id = '$_unpairedPrefix${d.id}';
        if (!found.containsKey(id)) {
          OrdiBackend.diag('headset-found', {'name': d.name, 'rssi': d.rssi});
          added = true;
        }
        found[id] = FoundDevice(id: id, name: d.name, rssi: d.rssi);
      }
      if (added) emit();
    }

    controller = StreamController<List<FoundDevice>>(
      onListen: () {
        if (!band) {
          _radio.searchHeadsets();
          lookAtPhone();
          look = Timer.periodic(const Duration(seconds: 2), (_) => lookAtPhone());
        }
        sub = _radio.scan().listen(
          (d) {
            nearby += 1;
            if (!(band ? isBand(d.name) : isAudios(d.name))) return;
            if (!found.containsKey(d.id)) {
              OrdiBackend.diag('ble-found', {
                'name': d.name,
                'rssi': d.rssi,
                'services': d.services,
                'connectable': d.connectable,
              });
            }
            found[d.id] = d;
            emit();
          },
          onError: controller.addError,
        );
        stop = Timer(timeout, () async {
          look?.cancel();
          await sub?.cancel();
          if (found.isEmpty) {
            // What was there instead, without naming anyone else's devices.
            OrdiBackend.diag('scan-empty', {
              'for': band ? 'band' : 'audios',
              'advertisements': nearby,
              'headsets': headsets,
            });
          }
          if (!controller.isClosed) await controller.close();
        });
      },
      onCancel: () async {
        stop?.cancel();
        look?.cancel();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  /// The live connection to each paired device, kept for as long as it is
  /// paired. Closing one is what disconnects.
  final Map<String, _Link> _links = {};

  /// How often the battery is read again while connected, for devices that
  /// do not announce changes themselves.
  static const batteryEvery = Duration(minutes: 1);

  /// Starts (or restarts) the standing connection to a device. With
  /// [waitForIt], resolves once connected and throws if that fails; without,
  /// returns at once and the device connects whenever it is in range.
  Future<void> _open(String id, {required bool band, bool waitForIt = false}) {
    _links.remove(id)?.close();
    final link = _links[id] = _Link(band);
    final first = waitForIt ? Completer<void>() : null;
    _dial(id, link, first: first);
    return first?.future.timeout(const Duration(seconds: 20)) ??
        Future<void>.value();
  }

  void _dial(String id, _Link link, {Completer<void>? first}) {
    link.state?.cancel();
    final waiting = first != null && !first.isCompleted;

    // A drop arrives as an event and then as the stream ending: once is
    // enough.
    var ended = false;
    void down() {
      if (ended || _links[id] != link) return;
      ended = true;
      _onDown(id, link);
      if (first != null && !first.isCompleted) {
        // The first attempt, from the pairing screen: report it, and leave
        // retrying to the person.
        first.completeError('Could not connect.');
      } else {
        _redial(id, link);
      }
    }

    link.state = _radio
        // Only the attempt someone is watching gives up. Every later one
        // stays open until the device is back in range.
        .link(id, timeout: waiting ? const Duration(seconds: 15) : null)
        .listen(
      (up) {
        if (_links[id] != link) return;
        if (!up) return down();
        link.attempts = 0;
        _onUp(id, link);
        if (first != null && !first.isCompleted) first.complete();
      },
      onError: (Object _) => down(),
      onDone: down,
    );
  }

  /// Tries again shortly: at once the first time, then further apart, so a
  /// phone with Bluetooth switched off is not asked every second.
  void _redial(String id, _Link link) {
    link.retry?.cancel();
    const waits = [1, 3, 5, 10, 15];
    final wait = Duration(seconds: waits[link.attempts.clamp(0, waits.length - 1)]);
    link.attempts += 1;
    link.retry = Timer(wait, () {
      if (_links[id] == link) _dial(id, link);
    });
  }

  void _show(_Link link, {required bool connected, int? battery}) {
    if (link.band) {
      bandConnected = connected;
      if (battery != null) bandBattery = battery;
    } else {
      audiosConnected = connected;
      if (battery != null) audiosBattery = battery;
    }
    notifyListeners();
  }

  void _onUp(String id, _Link link) {
    if (link.up) return;
    link.up = true;
    OrdiBackend.diag('ble-up', link.band ? 'band' : 'audios');
    _show(link, connected: true);
    unawaited(_watchBattery(id, link));
  }

  void _onDown(String id, _Link link) {
    link.battery?.cancel();
    link.poll?.cancel();
    if (link.up) OrdiBackend.diag('ble-down', link.band ? 'band' : 'audios');
    link.up = false;
    // A battery level is only shown while connected: an old one would be a
    // guess.
    _show(link, connected: false, battery: -1);
  }

  /// Reads the battery now, then keeps it current for as long as the link is
  /// up: from the device's own announcements, and by asking again every
  /// minute for devices that never announce.
  Future<void> _watchBattery(String id, _Link link) async {
    bool live() => _links[id] == link && link.up;

    try {
      final offered = await _radio.describe(id);
      if (!link.described) {
        link.described = true;
        OrdiBackend.diag('ble-gatt', offered.take(40).toList());
      }
    } catch (_) {
      // Diagnostics only.
    }
    if (!live()) return;

    Future<void> read() async {
      final level = await _radio.battery(id);
      if (!live()) return;
      if (level != link.lastBattery) {
        link.lastBattery = level;
        OrdiBackend.diag('ble-battery', level ?? 'none');
      }
      if (level != null) _show(link, connected: true, battery: level);
    }

    await read();
    if (!live()) return;
    link.battery?.cancel();
    link.battery = _radio.batteryUpdates(id).listen(
      (level) {
        if (live()) _show(link, connected: true, battery: level);
      },
      // No battery service, or one that cannot notify: the poll covers it.
      onError: (Object _) {},
    );
    link.poll?.cancel();
    link.poll = Timer.periodic(batteryEvery, (_) => read());
  }

  // Audios connected by the phone itself.

  /// How often the phone is asked whether the Audios are connected.
  static const phoneLinkEvery = Duration(seconds: 3);

  /// How long a newly paired headset is given to connect.
  static const pairedWait = Duration(seconds: 15);

  /// How long after connecting, with no battery to show, before looking at
  /// what the Audios broadcast instead. Late enough to stay out of the way of
  /// the Band search that follows the Audios in setup.
  static const surveyAfter = Duration(seconds: 45);
  Timer? _surveyTimer;
  bool _surveyed = false;

  /// One look at what is broadcasting within arm's reach, to learn whether
  /// Audios that offer no battery service say anything else at all. Sent as
  /// facts with no identifiers; once per launch.
  void _surveySoon() {
    if (_surveyed || _surveyTimer != null) return;
    _surveyTimer = Timer(surveyAfter, () {
      _surveyTimer = null;
      if (_surveyed || !audiosConnected || audiosBattery >= 0) return;
      _surveyed = true;
      final seen = <Object, Map<String, Object>>{};
      late final StreamSubscription<Map<String, Object>> sub;
      sub = _radio.survey().listen(
        (d) => seen[d['key'] ?? d] = {...d}..remove('key'),
        onError: (Object _) {},
      );
      Timer(const Duration(seconds: 8), () {
        sub.cancel();
        OrdiBackend.diag('ble-survey', seen.values.take(12).toList());
      });
    });
  }

  Timer? _phoneTimer;
  String? _phoneName;
  bool _askingPhone = false;
  String? _lastGatt;

  /// Starts following Audios that the phone connects by itself.
  Future<void> _followPhoneLink(String name) async {
    _phoneTimer?.cancel();
    _phoneName = name;
    _phoneTimer = Timer.periodic(phoneLinkEvery, (_) => _askPhone());
    await _askPhone();
  }

  void _stopFollowingPhoneLink() {
    _surveyTimer?.cancel();
    _surveyTimer = null;
    _phoneTimer?.cancel();
    _phoneTimer = null;
    _phoneName = null;
  }

  Future<void> _askPhone() async {
    final name = _phoneName;
    if (name == null || _askingPhone) return;
    _askingPhone = true;
    try {
      final linked = await _radio.linkedAudio(batteryFor: name);
      if (_phoneName != name) return;
      final here =
          linked.names.any((n) => n.toLowerCase() == name.toLowerCase());
      // A battery level is only shown while connected.
      final battery = here ? linked.battery : -1;
      if (here != audiosConnected) {
        OrdiBackend.diag(here ? 'audio-up' : 'audio-down', linked.names);
      }
      if (here) {
        final gatt = linked.gatt.join(', ');
        if (gatt != _lastGatt) {
          _lastGatt = gatt;
          OrdiBackend.diag('audio-gatt', linked.gatt);
        }
        if (battery != audiosBattery) OrdiBackend.diag('audio-battery', battery);
        if (battery < 0) _surveySoon();
      }
      if (here != audiosConnected || battery != audiosBattery) {
        audiosConnected = here;
        audiosBattery = battery;
        notifyListeners();
      }
    } finally {
      _askingPhone = false;
    }
  }

  /// A demo device "connects" after a realistic pause, with a battery level.
  Future<void> _linkDemo({required bool band}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (band) {
      bandConnected = true;
      bandBattery = 64;
    } else {
      audiosConnected = true;
      audiosBattery = 82;
    }
    notifyListeners();
  }

  /// Connects to a found device and remembers it as the Audios or the Band.
  /// From then on it reconnects by itself.
  Future<void> connect(FoundDevice found, {required bool band}) async {
    if (isDemo(found.id)) {
      await _linkDemo(band: band);
    } else if (isPhoneLinked(found.id)) {
      await _followPhoneLink(found.name);
      if (!audiosConnected) {
        // Switched off between being found and being tapped.
        _stopFollowingPhoneLink();
        throw StateError('Not connected.');
      }
    } else if (isUnpairedHeadset(found.id)) {
      final address = found.id.substring(_unpairedPrefix.length);
      final paired = await _radio.pairHeadset(address);
      OrdiBackend.diag('headset-paired', paired);
      if (!paired) throw StateError('Could not pair.');
      // Once paired, the phone connects the headset itself. Give it a moment.
      await _followPhoneLink(found.name);
      for (var i = 0; i < pairedWait.inSeconds && !audiosConnected; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await _askPhone();
      }
      if (!audiosConnected) {
        _stopFollowingPhoneLink();
        throw StateError('Paired, but not connected.');
      }
      // From here on they are Audios the phone connects, like any other.
      found = FoundDevice(
        id: '$_phonePrefix${found.name}',
        name: found.name,
        rssi: found.rssi,
      );
    } else {
      try {
        await _open(found.id, band: band, waitForIt: true);
      } catch (_) {
        _links.remove(found.id)?.close();
        rethrow;
      }
    }
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

  /// Starts the standing connection to whatever was paired before, quietly,
  /// at launch. Nothing waits on it: a device that is off or out of range
  /// simply connects when it comes back.
  Future<void> reconnect() async {
    for (final (id, band) in [(audiosId, false), (bandId, true)]) {
      if (id == null) continue;
      // A Band remembered from a build that offered one stays out of sight.
      if (band && !bandAvailable) continue;
      if (isDemo(id)) {
        await _linkDemo(band: band);
        continue;
      }
      if (isPhoneLinked(id)) {
        await _followPhoneLink(audiosName ?? id.substring(_phonePrefix.length));
        continue;
      }
      try {
        await _open(id, band: band);
      } catch (_) {
        // No Bluetooth at all: it shows as not connected.
      }
    }
  }

  /// Tries any paired device that is not connected right now, without waiting
  /// out its retry delay. Called when the app comes back to the front.
  void wake() {
    _askPhone();
    for (final MapEntry(key: id, value: link) in _links.entries) {
      if (link.up) continue;
      link.attempts = 0;
      link.retry?.cancel();
      _dial(id, link);
    }
  }

  /// Forgets a device so it can be set up again.
  Future<void> forget({required bool band}) async {
    final id = band ? bandId : audiosId;
    if (id != null) _links.remove(id)?.close();
    if (!band) _stopFollowingPhoneLink();
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
      link.close();
    }
    _links.clear();
    _phoneTimer?.cancel();
    _surveyTimer?.cancel();
    super.dispose();
  }
}

/// The standing connection to one paired device.
class _Link {
  _Link(this.band);

  final bool band;
  StreamSubscription<bool>? state;
  StreamSubscription<int>? battery;
  Timer? retry;
  Timer? poll;
  bool up = false;
  bool described = false;
  int attempts = 0;
  int? lastBattery = -2;

  void close() {
    state?.cancel();
    battery?.cancel();
    retry?.cancel();
    poll?.cancel();
  }
}
