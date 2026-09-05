import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the conversation is doing. Decided natively, because the transitions
/// are driven by audio timing that Dart never sees.
enum OrdiState { idle, listening, thinking, speaking }

/// One reading from the native engine.
class AudioFrame {
  const AudioFrame({
    required this.state,
    required this.amplitude,
    this.transcript = '',
    this.wake = false,
    this.error,
  });

  final OrdiState state;

  /// 0..1, already mapped from dBFS. While the user talks this is the
  /// microphone level; while Ordi talks it is the playback level, so the orb
  /// moves with whichever voice is speaking.
  final double amplitude;

  /// What Ordi is saying, growing as it speaks. Empty while idle or
  /// listening. Shown so the words can be read in a noisy room, with sound
  /// off, or after Ordi has stopped talking.
  final String transcript;

  /// True on the single frame where "Hey Ordi" was heard.
  final bool wake;

  /// Set when something went wrong that the user may need to know about.
  final String? error;

  static const silent = AudioFrame(state: OrdiState.idle, amplitude: 0);
}

/// Dart-side handle on the native audio engine.
///
/// Deliberately thin. Capture, echo cancellation, voice activity, the Gemini
/// socket, playback and barge-in all happen natively; nothing here sits on the
/// realtime path.
class OrdiAudio {
  OrdiAudio._();

  static const MethodChannel _methods = MethodChannel('ordi/audio');
  static const EventChannel _events = EventChannel('ordi/audio/events');

  static Stream<AudioFrame>? _frames;

  /// Whether a native implementation is present at all.
  ///
  /// Android is not implemented yet, and widget tests have no platform side.
  /// In both cases the app should degrade to a quiet, non-reactive orb rather
  /// than crash — so a missing implementation is a known state, not an error.
  static bool _unavailable = false;

  static Future<T?> _call<T>(String method, [Object? args]) async {
    if (_unavailable) return null;
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException {
      _unavailable = true;
      return null;
    }
  }

  /// Prompts for microphone access if it has not been decided yet.
  static Future<bool> requestPermission() async =>
      await _call<bool>('requestPermission') ?? false;

  /// Starts capture. Safe to call when already running.
  static Future<void> start() => _call<void>('start');

  /// Stops capture and releases the audio session back to the system.
  static Future<void> stop() => _call<void>('stop');

  static Future<bool> get isRunning async =>
      await _call<bool>('isRunning') ?? false;

  /// Diagnostic snapshot straight from the engine, over the method channel —
  /// which keeps working even when the event channel does not.
  static Future<Map<Object?, Object?>> stats() async =>
      await _call<Map<Object?, Object?>>('stats') ?? const {};

  /// Opens a live conversation.
  ///
  /// [token] is a short-lived token from our own backend, never the API key —
  /// the key stays server-side and the phone talks to Google directly.
  static Future<void> connect({
    required String token,
    required String model,
  }) =>
      _call<void>('connect', {'token': token, 'model': model});

  static Future<void> disconnect() => _call<void>('disconnect');

  /// Ask in text rather than speech. Ordi still answers out loud. Used for
  /// questions arriving via Siri, which are already words.
  static Future<void> ask(String text) => _call<void>('ask', {'text': text});

  /// A question Siri captured before the app was running, if any. Reading it
  /// clears it, so it is asked once rather than on every later launch.
  static Future<({String? text, double intentRanAt})> takePendingQuestion() async {
    final raw = await _call<Map<Object?, Object?>>('takePendingQuestion');
    final text = raw?['text'] as String?;
    return (
      text: (text == null || text.isEmpty) ? null : text,
      intentRanAt: (raw?['intentRanAt'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Clears the cached stream and the availability flag.
  ///
  /// Both are static because there is only ever one microphone, which is right
  /// for the app and awkward for tests — this lets each test start clean.
  @visibleForTesting
  static void resetForTesting() {
    _frames = null;
    _unavailable = false;
  }

  /// Live state and level, roughly 50 times a second.
  static Stream<AudioFrame> get frames {
    return _frames ??= _events.receiveBroadcastStream().map((event) {
      final map = (event as Map).cast<Object?, Object?>();
      return AudioFrame(
        state: _stateFrom(map['state'] as String?),
        amplitude: (map['amplitude'] as num?)?.toDouble() ?? 0,
        transcript: map['transcript'] as String? ?? '',
        wake: map['wake'] as bool? ?? false,
        error: map['error'] as String?,
      );
    }).asBroadcastStream();
  }

  static OrdiState _stateFrom(String? raw) => switch (raw) {
        'listening' => OrdiState.listening,
        'thinking' => OrdiState.thinking,
        'speaking' => OrdiState.speaking,
        _ => OrdiState.idle,
      };
}
