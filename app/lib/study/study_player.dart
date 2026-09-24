import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Reads study notes aloud on the phone's own speaker.
///
/// The Band is meant to be the canonical player once it exists; until then
/// this is the only place study content actually plays out loud, which is
/// exactly what "app can play them too" meant when this was scoped.
///
/// Ordi's own audio engine holds the iOS audio session open essentially all
/// the time — `.playAndRecord`/`.voiceChat`, so the mic can keep listening in
/// the background — and `flutter_tts` otherwise leaves the session alone by
/// default. `setSharedInstance` + `setIosAudioCategory` tell it to join
/// Ordi's already-active session instead of quietly contending with it.
class StudyPlayer {
  StudyPlayer() {
    _ready = _setUp();
  }

  final FlutterTts _tts = FlutterTts();

  /// Moves the output from the earpiece to the loudspeaker when that is where
  /// it landed. Implemented in `AppDelegate.swift`; a no-op elsewhere.
  static const _route = MethodChannel('ordi/route');
  final ValueNotifier<bool> speaking = ValueNotifier(false);

  /// The setup calls below are async native calls; the very first [playAll]
  /// used to fire before they'd actually completed, which is exactly the
  /// kind of race that only shows up "sometimes" — most taps land after
  /// setup finishes by luck, some don't. Every call now waits on this before
  /// touching the synthesizer at all.
  late final Future<void> _ready;

  Future<void> _setUp() async {
    await _tts.awaitSpeakCompletion(true);
    if (Platform.isIOS) {
      await _tts.setSharedInstance(true);
      // The *same* category, mode and options Ordi's engine already holds
      // (`OrdiEngine.swift`), so this joins its session instead of rewriting
      // it. flutter_tts's default is to reset the mode to `.default` and drop
      // the Bluetooth options, which quietly undid `.voiceChat` — the mode
      // that carries echo cancellation — for as long as Study Mode had been
      // opened. Keep this in step with the engine if that ever changes.
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playAndRecord,
        [
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
        IosTextToSpeechAudioMode.voiceChat,
      );
    }
  }

  /// Voice-chat sessions send sound to the earpiece — the small speaker at the
  /// top of the phone — unless told otherwise, which is right for a call and
  /// wrong for reading notes aloud. Asked for again on every utterance because
  /// iOS is free to re-pick the route whenever synthesis starts.
  Future<void> _preferSpeaker() async {
    if (!Platform.isIOS) return;
    try {
      await _route.invokeMethod<bool>('preferSpeaker');
    } catch (_) {
      // Best effort: the notes still play, just possibly from the earpiece.
    }
  }

  /// Bumped on every stop/replace so a stale sequential loop from a previous
  /// call knows to give up rather than talking over a newer one.
  int _generation = 0;

  Future<void> playAll(List<String> texts) async {
    final generation = ++_generation;
    await _ready;
    if (generation != _generation) return;

    // Without this, starting a new play while one utterance is still
    // in-flight doesn't interrupt it — the synthesizer queues the new text
    // behind the old one instead, so two notes end up speaking back to back
    // in the same breath. Stopping first guarantees a clean start every time.
    await _tts.stop();
    if (generation != _generation) return;

    speaking.value = true;
    for (final text in texts) {
      if (generation != _generation) return;
      if (text.trim().isEmpty) continue;
      await _preferSpeaker();
      // Once more just after it starts, since the route is often chosen only
      // when the first audio is produced.
      Future<void>.delayed(const Duration(milliseconds: 300), _preferSpeaker);
      await _tts.speak(text);
    }
    if (generation == _generation) speaking.value = false;
  }

  Future<void> stop() async {
    _generation++;
    speaking.value = false;
    await _tts.stop();
  }

  void dispose() {
    _tts.stop();
    speaking.dispose();
  }
}
