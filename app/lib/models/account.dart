import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session.dart';

/// One reply from the account API.
class ApiReply {
  const ApiReply(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

/// How requests reach the backend. Swapped for a fake in tests.
typedef AccountTransport = Future<ApiReply> Function(
  String method,
  String path, {
  Map<String, Object?>? body,
  String? bearer,
});

/// Something the person may need to see or act on.
class AccountFailure implements Exception {
  AccountFailure(this.code, this.message,
      {this.attemptsLeft, this.devices = const [], this.ticket});

  /// The server's own code (`bad_code`, `device_limit`, `slow_down`, …), or
  /// `offline` when the server could not be reached at all.
  final String code;
  final String message;
  final int? attemptsLeft;

  /// With `device_limit`: the phones already signed in, and a short-lived
  /// ticket that finishes sign-in once one of them is chosen to sign out.
  final List<AccountDevice> devices;
  final String? ticket;

  @override
  String toString() => message;
}

/// Today's allowance.
class Credits {
  const Credits({
    required this.unlimited,
    this.dailyLimit,
    this.left,
    this.heardLimit,
    this.heardLeft,
    this.resetsAt,
    this.unlimitedUntil,
  });

  final bool unlimited;
  final int? dailyLimit;
  final int? left;

  /// Listening: how many sentences Ordinary may hear in a day on the free
  /// allowance, answered or not, and how many remain. Null when there is no
  /// ceiling (unlimited, or a server from before the ceiling existed).
  final int? heardLimit;
  final int? heardLeft;

  /// When the daily allowance refills — midnight where the person is.
  final DateTime? resetsAt;
  final DateTime? unlimitedUntil;

  /// The day's answers are used up.
  bool get spent => !unlimited && (left ?? 1) <= 0;

  /// The day's listening is used up.
  bool get listenedOut => !unlimited && (heardLeft ?? 1) <= 0;

  /// Either allowance is gone: Ordinary rests until [resetsAt].
  bool get paused => spent || listenedOut;

  static Credits? from(Object? raw) {
    if (raw is! Map) return null;
    return Credits(
      unlimited: raw['tier'] == 'unlimited',
      dailyLimit: (raw['dailyLimit'] as num?)?.toInt(),
      left: (raw['creditsLeft'] as num?)?.toInt(),
      heardLimit: (raw['heardLimit'] as num?)?.toInt(),
      heardLeft: (raw['heardLeft'] as num?)?.toInt(),
      resetsAt: DateTime.tryParse(raw['resetsAt'] as String? ?? '')?.toLocal(),
      unlimitedUntil:
          DateTime.tryParse(raw['unlimitedUntil'] as String? ?? '')?.toLocal(),
    );
  }

  Map<String, Object?> toJson() => {
        'tier': unlimited ? 'unlimited' : 'free',
        'dailyLimit': dailyLimit,
        'creditsLeft': left,
        'heardLimit': heardLimit,
        'heardLeft': heardLeft,
        'resetsAt': resetsAt?.toUtc().toIso8601String(),
        'unlimitedUntil': unlimitedUntil?.toUtc().toIso8601String(),
      };

  Credits withLeft(int value) => Credits(
        unlimited: unlimited,
        dailyLimit: dailyLimit,
        left: value,
        heardLimit: heardLimit,
        heardLeft: heardLeft,
        resetsAt: resetsAt,
        unlimitedUntil: unlimitedUntil,
      );

  Credits withHeardLeft(int value) => Credits(
        unlimited: unlimited,
        dailyLimit: dailyLimit,
        left: left,
        heardLimit: heardLimit,
        heardLeft: value,
        resetsAt: resetsAt,
        unlimitedUntil: unlimitedUntil,
      );
}

/// A phone signed in to this account.
class AccountDevice {
  const AccountDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.current,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String platform;
  final bool current;
  final DateTime? lastSeenAt;

  static List<AccountDevice> listFrom(Object? raw) => [
        for (final d in raw is List ? raw : const [])
          if (d is Map)
            AccountDevice(
              id: '${d['id']}',
              name: d['name'] as String? ?? 'Phone',
              platform: d['platform'] as String? ?? '',
              current: d['current'] == true,
              lastSeenAt:
                  DateTime.tryParse(d['lastSeenAt'] as String? ?? '')?.toLocal(),
            ),
      ];
}

/// Where the sign-in secret lives: the Keychain on iPhone, the Keystore on
/// Android. Never in plain preferences.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainStore implements SecretStore {
  // Readable after the first unlock, so Ordinary can renew its sign-in while
  // the phone is locked in a pocket.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

enum AccountStatus { loading, signedOut, signedIn }

/// The signed-in owner: who they are, what they are allowed, and the tokens
/// that prove it to the backend.
///
/// Ordinary is for people who bought an Ordinary product. The backend decides
/// that from the store's order records; this class only carries the answer.
class Account extends ChangeNotifier {
  Account({AccountTransport? transport, SecretStore? secrets})
      : _send = transport ?? _http,
        _secrets = secrets ?? KeychainStore();

  /// Lets tests run the whole app without a backend or a keychain.
  @visibleForTesting
  static Account Function()? factoryForTesting;

  /// The app's account: the real one, unless a test has supplied its own.
  static Account create() => factoryForTesting?.call() ?? Account();

  /// An already signed-in owner with [left] credits and no network.
  @visibleForTesting
  factory Account.signedInForTesting({int left = 25, bool unlimited = false}) {
    final account = Account(
      transport: (method, path, {body, bearer}) async =>
          const ApiReply(200, {}),
      secrets: MemoryStore(),
    );
    account
      .._status = AccountStatus.signedIn
      ..email = 'owner@example.com'
      ..tier = unlimited ? 'unlimited' : 'free'
      .._installId = 'test-install-0000000000000000'
      .._access = 'test-access'
      .._accessExpiry = DateTime(2100)
      ..credits = Credits(
        unlimited: unlimited,
        dailyLimit: unlimited ? null : 25,
        left: unlimited ? null : left,
        resetsAt: DateTime(2100),
      );
    return account;
  }

  final AccountTransport _send;
  final SecretStore _secrets;

  static const _kInstall = 'ordinary_install_id';
  static const _kRefresh = 'ordinary_refresh_token';
  static const _kProfile = 'account_profile_v1';
  static const _kQueue = 'account_answer_queue_v1';

  /// Sentences heard and not yet reported, and the report being sent.
  static const _kHeard = 'account_heard_pending_v1';
  static const _kHeardBatch = 'account_heard_batch_v1';

  /// How many sentences are gathered before they are reported together: one
  /// request a sentence would be a request storm in a busy room.
  static const heardBatch = 10;

  AccountStatus _status = AccountStatus.loading;
  AccountStatus get status => _status;
  bool get signedIn => _status == AccountStatus.signedIn;

  String? email;
  String? name;

  /// `free` (the daily allowance), `unlimited`, or `none`.
  String tier = 'none';

  /// Why there is no access, when [tier] is `none`: `no_purchase`, `revoked`,
  /// `blocked`.
  String? reason;
  Credits? credits;
  List<AccountDevice> devices = const [];

  /// Signed in and allowed to use Ordinary.
  bool get hasAccess => signedIn && tier != 'none';

  /// Signed in, but today's answers are used up.
  /// True when today's answers or today's listening are used up.
  bool get outOfCredits => hasAccess && (credits?.paused ?? false);

  String? _installId;

  /// Identifies this install for good, unlike the per-launch id it replaces.
  String get installId => _installId ?? '';

  String? _access;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _refreshing;

  // ------------------------------------------------------------------ start

  /// Reads what was saved. Signed in straight away from the saved profile if
  /// there is one; the server is then asked in the background whether that is
  /// still true.
  Future<void> load() async {
    if (_status != AccountStatus.loading) return; // already set up (a test)
    // Listening counted on an earlier run and not yet reported.
    final saved = await SharedPreferences.getInstance();
    _heardUnreported = (saved.getInt(_kHeard) ?? 0) +
        (int.tryParse((saved.getString(_kHeardBatch) ?? '').split(' ').last) ?? 0);
    _installId = await _readSecret(_kInstall);
    if (_installId == null) {
      final random = Random.secure();
      _installId = List.generate(
          16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _writeSecret(_kInstall, _installId!);
    }

    final refresh = await _readSecret(_kRefresh);
    if (refresh == null) {
      _status = AccountStatus.signedOut;
      notifyListeners();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_kProfile) ?? '{}') as Map;
      email = saved['email'] as String?;
      name = saved['name'] as String?;
      tier = saved['tier'] as String? ?? 'free';
      reason = saved['reason'] as String?;
      credits = Credits.from(saved['credits']);
    } catch (_) {
      // A damaged cache only costs a moment until the refresh below lands.
    }
    _status = AccountStatus.signedIn;
    notifyListeners();
    unawaited(accessToken(force: true).then((_) => _flushAnswers()).then((_) => _flushHeard()).catchError((_) {}));
  }

  Future<String?> _readSecret(String key) async {
    try {
      return await _secrets.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSecret(String key, String value) async {
    try {
      await _secrets.write(key, value);
    } catch (_) {
      // No secure storage (a test host): held in memory for this run.
    }
  }

  // ---------------------------------------------------------------- sign-in

  /// Asks for a code to be emailed. The reply is the same whether or not the
  /// email belongs to an owner — the email itself says which.
  Future<void> start(String emailAddress) async {
    final reply = await _send('POST', '/auth/start',
        body: {'email': emailAddress.trim()});
    if (reply.status != 200) throw _failure(reply);
  }

  /// Finishes sign-in with the emailed [code], or with the [ticket] from a
  /// `device_limit` refusal plus the phone to sign out.
  Future<void> verify({
    String? emailAddress,
    String? code,
    String? ticket,
    String? replaceDeviceId,
  }) async {
    final reply = await _send('POST', '/auth/verify', body: {
      'email': ?emailAddress?.trim(),
      'code': ?code?.trim(),
      'ticket': ?ticket,
      'replaceDeviceId': ?replaceDeviceId,
      'installId': installId,
      'deviceName': _deviceName(),
      'platform': Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other'),
      'tz': _timezone(),
    });
    if (reply.status != 200) throw _failure(reply);
    await _applySession(reply.body);
    unawaited(_flushAnswers().then((_) => _flushHeard()));
  }

  static String _deviceName() {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'Android phone';
    return Platform.operatingSystem;
  }

  /// The IANA zone name where the platform gives one; the backend falls back
  /// to India time for anything it does not recognise.
  static String _timezone() {
    final now = DateTime.now();
    if (now.timeZoneName.contains('/')) return now.timeZoneName;
    // Phones report an abbreviation ("IST"), which is ambiguous; the offset is
    // not. One representative zone per offset is enough to put the daily reset
    // at local midnight.
    return _zoneForOffset[now.timeZoneOffset.inMinutes] ?? 'Asia/Kolkata';
  }

  static const Map<int, String> _zoneForOffset = {
    -600: 'Pacific/Honolulu',
    -480: 'America/Los_Angeles',
    -420: 'America/Denver',
    -360: 'America/Chicago',
    -300: 'America/New_York',
    -240: 'America/Halifax',
    -180: 'America/Sao_Paulo',
    0: 'UTC',
    60: 'Europe/Paris',
    120: 'Europe/Athens',
    180: 'Europe/Moscow',
    210: 'Asia/Tehran',
    240: 'Asia/Dubai',
    270: 'Asia/Kabul',
    300: 'Asia/Karachi',
    330: 'Asia/Kolkata',
    345: 'Asia/Kathmandu',
    360: 'Asia/Dhaka',
    390: 'Asia/Yangon',
    420: 'Asia/Bangkok',
    480: 'Asia/Singapore',
    540: 'Asia/Tokyo',
    570: 'Australia/Darwin',
    600: 'Australia/Brisbane',
    660: 'Pacific/Noumea',
    720: 'Pacific/Auckland',
  };

  AccountFailure _failure(ApiReply reply) {
    final code = reply.body['code'] as String? ?? 'error';
    final message = reply.body['error'] as String? ??
        'Something went wrong (${reply.status}). Try again.';
    return AccountFailure(
      code,
      message,
      attemptsLeft: (reply.body['attemptsLeft'] as num?)?.toInt(),
      devices: AccountDevice.listFrom(reply.body['devices']),
      ticket: reply.body['ticket'] as String?,
    );
  }

  Future<void> _applySession(Map<String, dynamic> body) async {
    final refresh = body['refreshToken'] as String?;
    if (refresh != null) await _writeSecret(_kRefresh, refresh);
    final access = body['accessToken'] as String?;
    if (access != null) {
      _access = access;
      final seconds = (body['expiresInSeconds'] as num?)?.toInt() ?? 900;
      // Renewed a minute early, so a request never leaves with a stale one.
      _accessExpiry = clock.now().add(Duration(seconds: max(30, seconds - 60)));
    }
    _applyProfile(body);
    _status = AccountStatus.signedIn;
    notifyListeners();
    await _saveProfile();
  }

  void _applyProfile(Map<String, dynamic> body) {
    final account = body['account'];
    if (account is Map) {
      email = account['email'] as String? ?? email;
      name = account['name'] as String? ?? name;
    }
    final entitlement = body['entitlement'];
    if (entitlement is Map) {
      tier = entitlement['tier'] as String? ?? tier;
      reason = entitlement['reason'] as String?;
    }
    if (body.containsKey('credits')) credits = Credits.from(body['credits']);
    if (body['devices'] is List) devices = AccountDevice.listFrom(body['devices']);
  }

  Future<void> _saveProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kProfile,
        jsonEncode({
          'email': email,
          'name': name,
          'tier': tier,
          'reason': reason,
          'credits': credits?.toJson(),
        }),
      );
    } catch (_) {}
  }

  // ----------------------------------------------------------------- tokens

  /// A token the backend will accept right now, renewed if need be. Null when
  /// signed out. Throws [AccountFailure] (`offline`) when it needs renewing
  /// and the server cannot be reached.
  Future<String?> accessToken({bool force = false}) {
    if (_status != AccountStatus.signedIn) return Future.value(null);
    if (!force && _access != null && clock.now().isBefore(_accessExpiry)) {
      return Future.value(_access);
    }
    // One renewal at a time: a refresh token works once, so two racing
    // renewals would sign the phone out.
    return _refreshing ??= _renew().whenComplete(() => _refreshing = null);
  }

  Future<String?> _renew() async {
    final refresh = await _readSecret(_kRefresh);
    if (refresh == null) {
      await _becomeSignedOut();
      return null;
    }
    final reply = await _send('POST', '/auth/refresh',
        body: {'refreshToken': refresh, 'installId': installId});
    if (reply.status == 200) {
      await _applySession(reply.body);
      return _access;
    }
    if (reply.status == 401) {
      await _becomeSignedOut();
      return null;
    }
    throw _failure(reply);
  }

  Future<void> _becomeSignedOut() async {
    try {
      await _secrets.delete(_kRefresh);
    } catch (_) {}
    _access = null;
    _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
    email = null;
    name = null;
    tier = 'none';
    reason = null;
    credits = null;
    devices = const [];
    _status = AccountStatus.signedOut;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kProfile);
      await prefs.remove(_kQueue);
      await prefs.remove(_kHeard);
      await prefs.remove(_kHeardBatch);
      _heardUnreported = 0;
    } catch (_) {}
    notifyListeners();
  }

  /// A signed request. A token that expired on the way is renewed once.
  Future<ApiReply> _authed(String method, String path,
      {Map<String, Object?>? body}) async {
    var token = await accessToken();
    if (token == null) return const ApiReply(401, {'code': 'signed_out'});
    var reply = await _send(method, path, body: body, bearer: token);
    if (reply.status == 401 && reply.body['code'] != 'signed_out') {
      token = await accessToken(force: true);
      if (token == null) return const ApiReply(401, {'code': 'signed_out'});
      reply = await _send(method, path, body: body, bearer: token);
    }
    if (reply.status == 401) await _becomeSignedOut();
    return reply;
  }

  // ---------------------------------------------------------------- profile

  /// Asks the server what this person is allowed now. Called on returning to
  /// the app, so a plan bought on the website shows up without signing in
  /// again.
  Future<void> refreshProfile() async {
    if (!signedIn) return;
    final reply = await _authed('GET', '/me');
    if (reply.status != 200) return;
    _applyProfile(reply.body);
    notifyListeners();
    await _saveProfile();
  }

  Future<void> signOut() async {
    try {
      await _authed('POST', '/auth/signout', body: const {});
    } catch (_) {
      // Signed out here regardless; the server forgets this phone when its
      // token lapses.
    }
    await _becomeSignedOut();
  }

  Future<void> removeDevice(String id) async {
    final reply =
        await _authed('POST', '/me/devices/remove', body: {'deviceId': id});
    if (reply.status != 200) throw _failure(reply);
    await refreshProfile();
  }

  /// Erases Ordinary's record of this person. Their order with the store is
  /// not part of it.
  Future<void> deleteAccount() async {
    final reply = await _authed('POST', '/me/delete', body: const {});
    if (reply.status != 200 && reply.status != 401) throw _failure(reply);
    await _becomeSignedOut();
  }

  // ---------------------------------------------------------------- credits

  /// The server's count, as it arrives with a session or a refusal.
  void applyCredits(Object? raw) {
    var next = Credits.from(raw);
    if (next == null) return;
    // The server only knows the sentences it has been told about. Those
    // heard since are taken off here too, or the count would jump back up
    // every time the server was asked anything.
    final known = next.heardLeft;
    if (known != null && _heardUnreported > 0) {
      next = next.withHeardLeft(max(0, known - _heardUnreported));
    }
    credits = next;
    tier = next.unlimited ? 'unlimited' : 'free';
    notifyListeners();
    unawaited(_saveProfile());
  }

  /// The server said this person no longer has access.
  void applyNoAccess(String? why) {
    tier = 'none';
    reason = why;
    credits = null;
    notifyListeners();
    unawaited(_saveProfile());
  }

  /// Ordinary answered: one credit. Shown at once; the server's count replaces
  /// it when the report lands. Reports wait in a saved queue while offline,
  /// each with its own id so a retry is never charged twice.
  Future<void> reportAnswer() async {
    if (!signedIn) return;
    final current = credits;
    if (current != null && !current.unlimited && current.left != null) {
      credits = current.withLeft(max(0, current.left! - 1));
      notifyListeners();
    }
    final random = Random.secure();
    final id = List.generate(
        12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_kQueue) ?? [];
    queue.add(id);
    // A long spell offline cannot grow this without end.
    await prefs.setStringList(
        _kQueue, queue.length > 200 ? queue.sublist(queue.length - 200) : queue);
    await _flushAnswers();
  }

  /// Counts one sentence Ordinary heard, whether or not it answered. Every
  /// sentence is paid for, and overheard talk is most of them, so the free
  /// allowance has a ceiling on listening as well as on answers. Reported a
  /// few at a time, and at once when the ceiling is reached.
  Future<void> reportHeard() async {
    if (!signedIn) return;
    var ranOut = false;
    final current = credits;
    if (current != null && !current.unlimited && current.heardLeft != null) {
      final left = max(0, current.heardLeft! - 1);
      ranOut = left == 0 && current.heardLeft! > 0;
      credits = current.withHeardLeft(left);
      notifyListeners();
    }
    _heardUnreported += 1;
    final prefs = await SharedPreferences.getInstance();
    final pending = (prefs.getInt(_kHeard) ?? 0) + 1;
    await prefs.setInt(_kHeard, pending);
    if (pending >= heardBatch || ranOut) await _flushHeard();
  }

  bool _flushingHeard = false;

  /// Sentences heard that the server has not counted yet: those waiting to
  /// fill a batch, and a batch still on its way.
  int _heardUnreported = 0;

  Future<void> _flushHeard() async {
    if (_flushingHeard || !signedIn) return;
    _flushingHeard = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // A report whose reply was lost is sent again under the same id, so it
      // is counted once. Only then is the next one made up.
      var batch = prefs.getString(_kHeardBatch);
      if (batch == null) {
        final pending = prefs.getInt(_kHeard) ?? 0;
        if (pending <= 0) return;
        final random = Random.secure();
        final id = List.generate(12,
                (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join();
        batch = '$id $pending';
        await prefs.setString(_kHeardBatch, batch);
        await prefs.setInt(_kHeard, max(0, (prefs.getInt(_kHeard) ?? 0) - pending));
      }
      final parts = batch.split(' ');
      final ApiReply reply;
      try {
        reply = await _authed('POST', '/usage/heard', body: {
          'batchId': parts.first,
          'count': int.tryParse(parts.last) ?? 1,
        });
      } on AccountFailure {
        return; // offline: sent with the next batch, or at the next launch
      }
      if (reply.status >= 500 || reply.status == 401) return;
      // Counted, or refused for good — either way it is finished with.
      await prefs.remove(_kHeardBatch);
      _heardUnreported =
          max(0, _heardUnreported - (int.tryParse(parts.last) ?? 0));
      if (reply.status == 200) applyCredits(reply.body);
      if (reply.status == 403) applyNoAccess(reply.body['code'] as String?);
    } finally {
      _flushingHeard = false;
    }
  }

  bool _flushing = false;

  Future<void> _flushAnswers() async {
    if (_flushing || !signedIn) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      while (signedIn) {
        final queue = prefs.getStringList(_kQueue) ?? [];
        if (queue.isEmpty) break;
        final ApiReply reply;
        try {
          reply = await _authed('POST', '/usage/answer',
              body: {'exchangeId': queue.first});
        } on AccountFailure {
          break; // offline: try again at the next answer or the next launch
        }
        if (reply.status >= 500) break;
        if (reply.status == 401) break; // signed out; the queue was cleared
        // Counted, or refused for good — either way it is finished with.
        final rest = (prefs.getStringList(_kQueue) ?? [])..remove(queue.first);
        await prefs.setStringList(_kQueue, rest);
        if (reply.status == 200) applyCredits(reply.body);
        if (reply.status == 403) applyNoAccess(reply.body['code'] as String?);
      }
    } finally {
      _flushing = false;
    }
  }

  // ------------------------------------------------------------- transport

  static Future<ApiReply> _http(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .openUrl(method, Uri.parse('${OrdiBackend.baseUrl}$path'))
          .timeout(const Duration(seconds: 12));
      request.headers.contentType = ContentType.json;
      if (OrdiBackend.clientSecret.isNotEmpty) {
        request.headers.set('x-ordi-key', OrdiBackend.clientSecret);
      }
      if (bearer != null) request.headers.set('authorization', 'Bearer $bearer');
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> decoded = const {};
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map<String, dynamic>) decoded = parsed;
      } catch (_) {
        // An error page from in front of the server; the status says enough.
      }
      return ApiReply(response.statusCode, decoded);
    } on AccountFailure {
      rethrow;
    } catch (_) {
      throw AccountFailure(
          'offline', "Can't reach Ordinary. Check your connection and try again.");
    } finally {
      client.close(force: true);
    }
  }
}
