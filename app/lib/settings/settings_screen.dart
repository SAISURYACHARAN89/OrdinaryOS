import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ordi_audio/ordi_audio.dart';

import '../models/ordi_settings.dart';
import '../models/recording_store.dart';
import '../ordi/ordi_controller.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// Reached from the round "O" in the top bar.
///
/// Two choices, both sent with the next session request: which voice Ordi
/// speaks in, and which language it should start out in. The voice is pinned
/// into the session token, so picking one restarts the session right away —
/// otherwise the change would wait up to half an hour for the token to expire
/// — and Ordi says a line in the new voice so the choice can be heard.
///
/// A tapped voice tile tells its own story: it fills black, shows a loader
/// while the session is switching, then a live level meter while the sample is
/// actually being spoken, then settles on a tick.
///
/// Everything it needs is passed in rather than read from `OrdiScope`: the
/// scope sits inside the app's `home`, so a pushed route is above it and
/// cannot see it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.controller,
    required this.recordings,
  });

  final OrdiSettings settings;
  final OrdiController controller;
  final RecordingStore recordings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _Phase { idle, loading, speaking }

class _SettingsScreenState extends State<SettingsScreen> {
  /// The tile currently doing something, and what it is doing.
  String? _activeKey;
  _Phase _phase = _Phase.idle;

  /// Shown only when there is something the tiles cannot say for themselves.
  String? _note;

  Timer? _settle;
  Timer? _giveUp;

  /// Bumped on every tap, so the result of an earlier tap that finishes after
  /// a later one can be recognised and ignored.
  int _pick = 0;

  /// False from the moment of a tap until the sample has actually been asked
  /// for. Until then any "speaking" is the previous voice finishing (or being
  /// cut off), not the new sample, and must not flip the tile to its meter.
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.reading.addListener(_onReading);
  }

  @override
  void dispose() {
    widget.controller.reading.removeListener(_onReading);
    _settle?.cancel();
    _giveUp?.cancel();
    super.dispose();
  }

  /// Watches Ordi's own state to know when the sample really starts and ends,
  /// rather than guessing from timers.
  void _onReading() {
    if (_activeKey == null || !_armed) return;
    final speaking = widget.controller.reading.value.state == OrdiState.speaking;

    if (speaking) {
      _settle?.cancel();
      if (_phase != _Phase.speaking) setState(() => _phase = _Phase.speaking);
    } else if (_phase == _Phase.speaking) {
      // A short pause inside a sentence is not the end of it.
      _settle ??= Timer(const Duration(milliseconds: 900), _finish);
    }
  }

  void _finish() {
    _settle = null;
    _giveUp?.cancel();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _activeKey = null;
    });
  }

  void _begin(String key) {
    _settle?.cancel();
    _settle = null;
    _giveUp?.cancel();
    // If Ordi never starts speaking, do not leave a loader spinning forever.
    _giveUp = Timer(const Duration(seconds: 14), _finish);
    _armed = false;
    setState(() {
      _activeKey = key;
      _phase = _Phase.loading;
      _note = null;
    });
  }

  Future<void> _pickVoice(OrdiVoice voice) async {
    final settings = widget.settings;
    final controller = widget.controller;
    final same = settings.voice == voice.key;

    // Same voice while its own sample is still on its way: nothing to do.
    if (same && _activeKey == voice.key && _phase == _Phase.loading) return;

    // Restarting mid-recording would cut the session Ordi is quietly taking
    // notes in, so the choice is saved and applies once it ends.
    if (widget.recordings.isRecording) {
      if (!same) settings.setVoice(voice);
      setState(() => _note =
          '${voice.name} is saved. It starts once the recording ends.');
      return;
    }

    // Tapping another voice at any point — mid-switch, mid-sample — just
    // moves on to it: the newest tap wins and the controller skips the ones
    // it overtook.
    final pick = ++_pick;
    if (!same) settings.setVoice(voice);
    _begin(voice.key);

    // Same voice: just say the sample again. New voice: restart the session,
    // which introduces itself as soon as it is connected.
    final ok = same
        ? await controller.speak('[ordi] hello')
        : await controller.restart(introduce: true);
    if (!mounted || pick != _pick) return;
    if (ok) {
      _armed = true;
      _onReading(); // in case it already started
    }
    if (!ok) {
      _finish();
      setState(() => _note = same
          ? 'Ordi is not connected right now, so it cannot play a sample.'
          : '${voice.name} is saved. It starts the next time Ordi connects.');
    }
  }

  Future<void> _pickLanguage(String language) async {
    final settings = widget.settings;
    if (settings.language == language) return;
    settings.setLanguage(language);

    if (widget.recordings.isRecording) {
      setState(() => _note = 'Saved. It applies once the recording ends.');
      return;
    }
    setState(() => _note = null);
    final ok = await widget.controller.restart();
    if (!mounted || ok) return;
    setState(() => _note = 'Saved. It applies the next time Ordi connects.');
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: 'Settings'),
        body: AnimatedBuilder(
          animation: settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(
                Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
            children: [
              const _Label('Voice'),
              LayoutBuilder(builder: (context, constraints) {
                final width = (constraints.maxWidth - Tokens.x2) / 2;
                return Wrap(
                  spacing: Tokens.x2,
                  runSpacing: Tokens.x2,
                  children: [
                    for (final voice in ordiVoices)
                      SizedBox(
                        width: width,
                        child: _VoiceTile(
                          voice: voice,
                          selected: settings.voice == voice.key,
                          phase: _activeKey == voice.key
                              ? _phase
                              : _Phase.idle,
                          reading: widget.controller.reading,
                          onTap: () => _pickVoice(voice),
                        ),
                      ),
                  ],
                );
              }),
              const _Label('Language'),
              Wrap(
                spacing: Tokens.x2,
                runSpacing: Tokens.x2,
                children: [
                  _LanguageChip(
                    label: 'Automatic',
                    selected: settings.language.isEmpty,
                    onTap: () => _pickLanguage(''),
                  ),
                  for (final language in ordiLanguages)
                    _LanguageChip(
                      label: language.native,
                      selected: settings.language == language.name,
                      onTap: () => _pickLanguage(language.name),
                    ),
                ],
              ),
              if (_note != null) ...[
                const SizedBox(height: Tokens.x5),
                Text(_note!, style: Tokens.caption.copyWith(fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Tokens.x6, bottom: Tokens.x2),
      child: Text(text.toUpperCase(), style: Tokens.label),
    );
  }
}

class _VoiceTile extends StatelessWidget {
  const _VoiceTile({
    required this.voice,
    required this.selected,
    required this.phase,
    required this.reading,
    required this.onTap,
  });

  final OrdiVoice voice;
  final bool selected;
  final _Phase phase;
  final ValueListenable<Reading> reading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The tile is black while it is the choice or is being auditioned.
    final dark = selected || phase != _Phase.idle;
    final ink = dark ? Tokens.accentInk : Tokens.text;

    return Surface(
      radius: 18,
      fill: dark ? Tokens.text : Tokens.paper2,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: Tokens.x4, vertical: Tokens.x3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  style: Tokens.heading.copyWith(fontSize: 16, color: ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: Text(voice.name),
                ),
                const SizedBox(height: 2),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  style: Tokens.caption.copyWith(
                    color: dark
                        ? Tokens.accentInk.withValues(alpha: 0.7)
                        : Tokens.textFaint,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: Text('${voice.trait} · ${voice.description}'),
                ),
              ],
            ),
          ),
          const SizedBox(width: Tokens.x2),
          SizedBox(
            width: 26,
            height: 22,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: switch (phase) {
                _Phase.loading =>
                  const _LoadingDots(key: ValueKey('loading')),
                _Phase.speaking =>
                  _LevelMeter(key: const ValueKey('speaking'), reading: reading),
                _Phase.idle => selected
                    ? const Align(
                        key: ValueKey('tick'),
                        alignment: Alignment.centerRight,
                        child: Icon(Icons.check_rounded,
                            size: 18, color: Tokens.accentInk),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Three dots rising and falling in turn — "getting the voice ready".
class _LoadingDots extends StatefulWidget {
  const _LoadingDots({super.key});

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
              child: Transform.translate(
                offset: Offset(
                    0, -4 * math.max(0, math.sin((_c.value - i * 0.16) * 2 * math.pi))),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Tokens.accentInk.withValues(alpha: 0.5 + 0.5 * (i + 1) / 3),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bars that move with the actual level of Ordi's voice, so the tile visibly
/// speaks while the sample plays.
class _LevelMeter extends StatefulWidget {
  const _LevelMeter({super.key, required this.reading});

  final ValueListenable<Reading> reading;

  @override
  State<_LevelMeter> createState() => _LevelMeterState();
}

class _LevelMeterState extends State<_LevelMeter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_c, widget.reading]),
      builder: (context, _) {
        final level = widget.reading.value.amplitude.clamp(0.0, 1.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < 5; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                child: Container(
                  width: 3,
                  // A floor so the bars never vanish in a quiet moment, the
                  // real level on top, and a per-bar wobble so they do not
                  // move in lock-step.
                  height: 4 +
                      16 *
                          (0.25 + 0.75 * level.clamp(0.0, 1.0)) *
                          (0.5 +
                              0.5 *
                                  math.sin(_c.value * 2 * math.pi + i * 1.1)
                                      .abs()),
                  decoration: BoxDecoration(
                    color: Tokens.accentInk,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(
            horizontal: Tokens.x4, vertical: Tokens.x3 - 2),
        decoration: BoxDecoration(
          color: selected ? Tokens.text : Tokens.paper2,
          borderRadius: BorderRadius.circular(Tokens.rPill),
        ),
        child: Text(
          label,
          style: Tokens.bodyStrong.copyWith(
            fontSize: 14,
            color: selected ? Tokens.accentInk : Tokens.text,
          ),
        ),
      ),
    );
  }
}
