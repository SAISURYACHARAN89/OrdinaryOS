import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/account.dart';

/// A short-lived permit to talk to Gemini.
class SessionToken {
  const SessionToken({required this.token, required this.model});

  final String token;
  final String model;
}

/// What a finished conversation turned out to be about.
class SessionInsights {
  const SessionInsights({
    required this.title,
    required this.summary,
    required this.tasks,
  });

  final String title;
  final String summary;
  final List<String> tasks;
}

class SessionRefused implements Exception {
  SessionRefused(this.message, {this.permanent = false, this.code});

  final String message;

  /// The server's reason, when it gave one: `out_of_credits`, `no_purchase`,
  /// `revoked`, `signed_out`, …
  final String? code;

  /// True when retrying cannot help — the daily cap is spent, or the app and
  /// server disagree about the shared key. Backing off and trying again would
  /// just delay telling the user something they need to act on.
  final bool permanent;

  @override
  String toString() => message;
}

/// Fetches session tokens from our own backend.
///
/// The API key never reaches the phone: the backend holds it, mints a token
/// that expires in minutes, and pins the model and system instruction into
/// that token so a modified client cannot change them. The phone then talks to
/// Google directly — no audio passes through our server, because a relay hop
/// on every chunk is the latency this product is built to avoid.
class OrdiBackend {
  OrdiBackend._();

  /// Override when running against a Mac on the same Wi-Fi:
  ///   flutter run --dart-define=ORDI_BACKEND=http://192.168.1.20:8787
  static const String baseUrl = String.fromEnvironment(
    'ORDI_BACKEND',
    defaultValue: 'http://localhost:8787',
  );

  /// Shared secret for the backend, supplied at build time:
  ///   --dart-define=ORDI_CLIENT_SECRET=...
  ///
  /// This is not real authentication — it ships inside the app and can be
  /// extracted by anyone determined. It exists so that a leaked URL is not
  /// immediately free Gemini credit for strangers. Proper per-user auth
  /// arrives with accounts.
  static const String clientSecret =
      String.fromEnvironment('ORDI_CLIENT_SECRET');

  /// The names of the PDFs the person has added, read at each session
  /// request. With any, the backend gives Ordinary a tool to search them and
  /// tells it what there is; with none, the tool is not offered at all.
  static List<String> Function()? documentTitles;

  /// The signed-in owner. Set once by the app; every session is requested in
  /// their name and counted against their allowance.
  static Account? account;

  static String? _deviceId;

  /// Identifies this install: the account's saved id once it has loaded, and
  /// a throwaway one before that (diagnostics sent during startup).
  static String get deviceId {
    final saved = account?.installId ?? '';
    if (saved.isNotEmpty) return saved;
    return _deviceId ??= List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Lets tests supply a token without standing up a server, and without the
  /// widget tests quietly making real network calls.
  @visibleForTesting
  static Future<SessionToken> Function()? stub;

  /// Same idea as [stub], for [requestSessionInsights].
  @visibleForTesting
  static Future<SessionInsights?> Function(String transcript)? insightsStub;

  /// Fire-and-forget development telemetry.
  ///
  /// iOS device logs cannot be streamed from the command line on current
  /// macOS, so this is how on-device behaviour becomes visible. Never awaited
  /// and never throws — diagnostics must not be able to break the thing they
  /// are diagnosing.
  static void diag(String event, [Object? detail]) {
    if (!_shouldSend(event, DateTime.now())) return;
    diagSpy?.call(event);
    if (stub != null) return; // tests do not phone home
    _post(event, detail);
  }

  static void _post(String event, Object? detail) {
    () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      try {
        final request = await client.postUrl(Uri.parse('$baseUrl/diag'));
        request.headers.contentType = ContentType.json;
        if (clientSecret.isNotEmpty) {
          request.headers.set('x-ordi-key', clientSecret);
        }
        request.write(jsonEncode({
          'deviceId': deviceId,
          'event': event,
          'detail': ?detail,
        }));
        await request.close();
      } catch (_) {
        // Losing a diagnostic is not worth surfacing.
      } finally {
        client.close(force: true);
      }
    }();
  }

  /// How much reaches the server, set at build time:
  ///   --dart-define=ORDI_DIAG=full    everything (test and TestFlight builds)
  ///   --dart-define=ORDI_DIAG=events  important events only (the default)
  ///   --dart-define=ORDI_DIAG=off     nothing
  ///
  /// `full` sent a heartbeat every five seconds and a line on every listening
  /// state change — tens of thousands of requests per phone per day, fine for
  /// a handful of testers and far too many for real users.
  static const String diagLevel =
      String.fromEnvironment('ORDI_DIAG', defaultValue: 'events');

  /// Frequent, routine events: only worth sending when actively debugging.
  static const Set<String> fullOnlyEvents = {
    'heartbeat',
    'state',
    'frame',
    'lifecycle',
    'subscribed',
    'mic-started',
    'resuming',
    'siri-check',
  };

  /// In `events` mode, at most this many posts an hour — a reconnect storm
  /// must not turn into a request storm.
  static const int eventsPerHour = 60;

  /// Lets tests set the level and watch what would be sent.
  @visibleForTesting
  static String? diagLevelOverride;
  @visibleForTesting
  static void Function(String event)? diagSpy;

  static DateTime? _windowStart;
  static int _sentInWindow = 0;
  static bool _throttledNoted = false;

  @visibleForTesting
  static void resetDiagForTesting() {
    _windowStart = null;
    _sentInWindow = 0;
    _throttledNoted = false;
  }

  static bool _shouldSend(String event, DateTime now) {
    final level = diagLevelOverride ?? diagLevel;
    if (level == 'off') return false;
    if (level == 'full') return true;
    if (fullOnlyEvents.contains(event)) return false;

    final start = _windowStart;
    if (start == null || now.difference(start) >= const Duration(hours: 1)) {
      _windowStart = now;
      _sentInWindow = 0;
      _throttledNoted = false;
    }
    if (_sentInWindow < eventsPerHour) {
      _sentInWindow++;
      return true;
    }
    // One marker saying events were dropped, then silence until the hour
    // turns over.
    if (!_throttledNoted && event != 'throttled') {
      _throttledNoted = true;
      diagSpy?.call('throttled');
      if (stub == null) _post('throttled', {'dropped-after': eventsPerHour});
    }
    return false;
  }

  /// ISO-8601 local time with the offset, e.g. 2026-09-19T18:04:22+05:30.
  /// `DateTime.toIso8601String` drops the offset for local times, which would
  /// leave the model guessing at the timezone.
  static String _localNow() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final stamp = now.toIso8601String().split('.').first;
    return '$stamp$sign$hours:$minutes';
  }

  /// [memory] is a short, plain-text digest of recent conversations — see
  /// `ConversationLog.recentDigest` — folded into the system instruction for
  /// this one session so Ordi can answer being asked about something already
  /// discussed. Omitted entirely when there is nothing to send yet.
  ///
  /// [resumeHandle] is a checkpoint from a conversation that just dropped —
  /// see `OrdiController`'s use of `AudioFrame.resumptionHandle` — asking the
  /// new session to pick up where that one left off instead of starting
  /// fresh. Omitted for an ordinary first connect.
  ///
  /// [voice], [accent] and [language] are the person's choices from Settings. Both are
  /// optional and validated by the backend, which falls back to its own
  /// default voice and to no language hint.
  static Future<SessionToken> requestSession({
    String? memory,
    String? resumeHandle,
    String? voice,
    String? accent,
    String? language,
  }) async {
    final stubbed = stub;
    if (stubbed != null) return stubbed();

    final owner = account;
    String? bearer;
    if (owner != null) {
      if (!owner.signedIn) {
        throw SessionRefused('Sign in to use Ordinary.',
            permanent: true, code: 'signed_out');
      }
      try {
        bearer = await owner.accessToken();
      } on AccountFailure catch (error) {
        throw SessionRefused(error.message); // offline: worth retrying
      }
      if (bearer == null) {
        throw SessionRefused('Sign in to use Ordinary.',
            permanent: true, code: 'signed_out');
      }
    }

    final titles = documentTitles?.call() ?? const <String>[];
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/session'));
      request.headers.contentType = ContentType.json;
      if (clientSecret.isNotEmpty) {
        request.headers.set('x-ordi-key', clientSecret);
      }
      if (bearer != null) request.headers.set('authorization', 'Bearer $bearer');
      request.write(jsonEncode({
        'deviceId': deviceId,
        'memory': ?memory,
        'resumeHandle': ?resumeHandle,
        // The model has no clock, so "remind me at six" is unresolvable
        // without this. Sent with the offset so it means six where the phone
        // is, not six UTC.
        'now': _localNow(),
        // This build answers tool calls. The backend only declares tools — and
        // only switches on wake gating, which is expressed as a tool — for
        // clients that say so; older builds would freeze on the first one.
        'tools': true,
        // This build also answers update_reminder and cancel_reminder.
        'toolsV2': true,
        // …and takes reminder times as in_minutes / date / time.
        'toolsV3': true,
        // …and reads app data, acts in bulk, and opens study mode.
        'toolsV4': true,
        // …and searches the person's own PDFs, when they have any.
        'toolsV5': true,
        // …and tells the time from the phone's clock when asked.
        'toolsV6': true,
        if (titles.isNotEmpty) 'documents': true,
        if (titles.isNotEmpty) 'documentTitles': titles.take(12).toList(),
        'voice': ?voice,
        if (accent != null && accent.isNotEmpty) 'accent': accent,
        if (language != null && language.isNotEmpty) 'language': language,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      // A proxy in front of the server can answer with an HTML error page.
      // That is a passing fault, to be retried — not a reason to stop.
      Map<String, dynamic> decoded = const {};
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map<String, dynamic>) decoded = parsed;
      } on FormatException {
        if (response.statusCode == 200) {
          throw SessionRefused('Backend sent an unreadable reply.');
        }
      }
      final code = decoded['code'] as String?;

      if (response.statusCode == 401 && owner != null && code != null) {
        // The sign-in lapsed between renewing it and using it, or this phone
        // was signed out elsewhere. Renewing settles which; the retry that
        // follows goes out with whatever that produced.
        if (code != 'signed_out') {
          try {
            await owner.accessToken(force: true);
          } on AccountFailure catch (error) {
            throw SessionRefused(error.message);
          }
          if (owner.signedIn) throw SessionRefused('Signing in again…');
        }
        throw SessionRefused('Sign in to use Ordinary.',
            permanent: true, code: 'signed_out');
      }
      if (response.statusCode == 402) {
        owner?.applyCredits(decoded);
        throw SessionRefused(
          decoded['error'] as String? ?? 'Daily limit reached.',
          permanent: true,
          code: code ?? 'out_of_credits',
        );
      }
      if (response.statusCode == 403 && code != null) {
        owner?.applyNoAccess(code);
        throw SessionRefused(
          decoded['error'] as String? ?? 'Ordinary is for Ordinary owners.',
          permanent: true,
          code: code,
        );
      }
      if (response.statusCode == 401) {
        throw SessionRefused(
          'Ordinary was refused by its backend.\n'
          'The app and server disagree about the shared key.',
          permanent: true,
        );
      }
      if (response.statusCode == 429) {
        throw SessionRefused(
          decoded['error'] as String? ?? 'Daily limit reached.',
          permanent: true,
        );
      }
      if (response.statusCode != 200) {
        throw SessionRefused(
          decoded['detail'] as String? ??
              decoded['error'] as String? ??
              'Backend returned ${response.statusCode}.',
        );
      }

      final token = decoded['token'] as String?;
      final model = decoded['model'] as String?;
      if (token == null || model == null) {
        throw SessionRefused('Backend response was missing the token.');
      }
      owner?.applyCredits(decoded['credits']);
      return SessionToken(token: token, model: model);
    } on SocketException {
      throw SessionRefused(
        'Cannot reach Ordinary\'s backend at $baseUrl.\n'
        'Is the token service running, and is this device on the same network?',
      );
    } on HttpException catch (error) {
      // The connection dropped mid-reply. Like any other network fault, this
      // must reach the reconnect path rather than escape it.
      throw SessionRefused('Connection to Ordinary dropped: ${error.message}');
    } on TimeoutException {
      throw SessionRefused('Ordinary took too long to answer.');
    } finally {
      client.close(force: true);
    }
  }

  /// Asks the backend to title, summarise, and pull tasks out of one finished
  /// conversation. Runs once per conversation, not on any kind of schedule.
  ///
  /// Returns null on any failure rather than throwing — this is background
  /// enrichment, not something the user is waiting on. A session that fails
  /// to summarise just stays untitled in History rather than surfacing an
  /// error for something nobody asked for directly.
  static Future<SessionInsights?> requestSessionInsights(
    String transcript,
  ) async {
    final stubbed = insightsStub;
    if (stubbed != null) return stubbed(transcript);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request =
          await client.postUrl(Uri.parse('$baseUrl/session-insights'));
      request.headers.contentType = ContentType.json;
      if (clientSecret.isNotEmpty) {
        request.headers.set('x-ordi-key', clientSecret);
      }
      final bearer = await account?.accessToken();
      if (bearer != null) request.headers.set('authorization', 'Bearer $bearer');
      request.write(jsonEncode({'transcript': transcript}));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final title = decoded['title'] as String?;
      final summary = decoded['summary'] as String?;
      if (title == null || summary == null) return null;

      return SessionInsights(
        title: title,
        summary: summary,
        tasks: (decoded['tasks'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
