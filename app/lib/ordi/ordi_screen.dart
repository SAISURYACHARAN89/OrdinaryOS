import 'package:flutter/material.dart';

import '../spoken_text.dart';
import '../ui/glass.dart';
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

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text('Ordi', style: Tokens.heading),
          centerTitle: true,
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
                const SizedBox(height: Tokens.x8),

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
