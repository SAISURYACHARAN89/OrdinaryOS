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

class SessionRefused implements Exception {
  SessionRefused(this.message);
  final String message;

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

  static Future<SessionToken> requestSession() async {
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
      request.write(jsonEncode({'deviceId': deviceId}));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 401) {
        throw SessionRefused(
          'Ordi was refused by its backend.\n'
          'The app and server disagree about the shared key.',
        );
      }
      if (response.statusCode == 429) {
        throw SessionRefused(
          decoded['error'] as String? ?? 'Daily limit reached.',
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
}
