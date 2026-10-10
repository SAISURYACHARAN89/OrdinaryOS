import 'package:flutter/material.dart';
import 'package:ordi_audio/ordi_audio.dart' show OrdiState;

import '../documents/documents_screen.dart';
import '../history/chat_screen.dart';
import '../models/conversation_log.dart';
import '../main.dart';
import '../spoken_text.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';
import 'ordi_controller.dart';
import 'waveform.dart';

/// Talking to Ordi.
///
/// Renders only — the microphone and the session are owned by
/// [OrdiController], which outlives this screen so that leaving it does not
/// stop Ordi listening.
class OrdiScreen extends StatelessWidget {
  const OrdiScreen({super.key, required this.controller});

  final OrdiController controller;

  String _stateLabel(OrdiState state) {
    if (controller.micDenied) return 'MICROPHONE OFF';
    if (!controller.connected) return 'CONNECTING…';
    return switch (state) {
      OrdiState.idle => 'SAY "HEY ORDINARY"',
      OrdiState.listening => 'LISTENING…',
      OrdiState.thinking => 'THINKING…',
      OrdiState.speaking => 'SPEAKING',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(
          context,
          text: 'Ordinary',
          actions: [
            // Type to Ordinary instead of speaking. Carries on the
            // conversation in progress, or starts a new one.
            IconButton(
              tooltip: 'Chat',
              icon: const Icon(Icons.chat_bubble_outline_rounded,
                  color: Tokens.text, size: 24),
              onPressed: () {
                final log = OrdiScope.maybeLogOf(context);
                final latest = log == null || log.sessions.isEmpty
                    ? null
                    : log.sessions.first;
                final current = latest != null &&
                        DateTime.now().difference(latest.endedAt) <=
                            ConversationLog.sessionGap
                    ? latest
                    : null;
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => ChatScreen(session: current)),
                );
              },
            ),
            // The PDFs Ordinary can answer from.
            if (OrdiScope.maybeDocumentsOf(context) case final library?)
              IconButton(
                tooltip: 'Documents',
                icon: const Icon(Icons.description_outlined,
                    color: Tokens.text, size: 24),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DocumentsScreen(library: library),
                  ),
                ),
              ),
            const SizedBox(width: Tokens.x2),
          ],
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Column(
              children: [
                const Spacer(),
                ValueListenableBuilder<Reading>(
                  valueListenable: controller.reading,
                  builder: (context, reading, _) => Waveform(
                    state: reading.state,
                    amplitude: reading.amplitude,
                    width: MediaQuery.sizeOf(context).width * 0.72,
                    height: 72,
                  ),
                ),
                const SizedBox(height: Tokens.x5),
                // What Ordi is doing, in words, under the waveform.
                ValueListenableBuilder<Reading>(
                  valueListenable: controller.reading,
                  builder: (context, reading, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _stateLabel(reading.state),
                      key: ValueKey(_stateLabel(reading.state)),
                      style: Tokens.label.copyWith(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: Tokens.x6),

                // What Ordi is saying, as it says it.
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.gutter + Tokens.x2),
                  child: ValueListenableBuilder<String>(
                    valueListenable: controller.transcript,
                    builder: (context, text, _) => SpokenText(text: text),
                  ),
                ),
                const Spacer(),

                if (controller.problem != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Tokens.x8, 0, Tokens.x8, Tokens.x8),
                    child: Text(
                      controller.problem!,
                      textAlign: TextAlign.center,
                      style: Tokens.body.copyWith(color: Tokens.textFaint),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
