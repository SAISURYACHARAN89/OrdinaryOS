import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

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
  SessionRefused(this.message, {this.permanent = false});

  final String message;

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

  /// Identifies this install to the usage cap.
  ///
  /// Held in memory for now, so it changes on every launch and the cap is
  /// effectively per-session. That is knowingly weak — the cap was accepted as
  /// bypassable for v1 — and is the thing to replace when usage limits start
  /// mattering.
  static String? _deviceId;

  static String get deviceId {
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
    if (stub != null) return; // tests do not phone home
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

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/session'));
      request.headers.contentType = ContentType.json;
      if (clientSecret.isNotEmpty) {
        request.headers.set('x-ordi-key', clientSecret);
      }
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
        'voice': ?voice,
        if (accent != null && accent.isNotEmpty) 'accent': accent,
        if (language != null && language.isNotEmpty) 'language': language,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 401) {
        throw SessionRefused(
          'Ordi was refused by its backend.\n'
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
      return SessionToken(token: token, model: model);
    } on SocketException {
      throw SessionRefused(
        'Cannot reach Ordi\'s backend at $baseUrl.\n'
        'Is the token service running, and is this device on the same network?',
      );
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
