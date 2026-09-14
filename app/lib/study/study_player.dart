import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
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
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playAndRecord,
        [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
        ],
      );
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
