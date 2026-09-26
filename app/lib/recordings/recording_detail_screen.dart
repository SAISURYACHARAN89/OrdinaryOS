import 'package:flutter/material.dart';

import '../models/recording_store.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';
import 'recordings_screen.dart' show confirmDeleteRecording;

/// The full transcript behind one recording.
///
/// One row per utterance rather than per exchange, because in a recording
/// there is no exchange — Ordi was silent throughout. What is captured is the
/// person's side of a conversation with someone else.
class RecordingDetailScreen extends StatelessWidget {
  const RecordingDetailScreen({
    super.key,
    required this.recording,
    required this.store,
  });

  final Recording recording;
  final RecordingStore store;

  @override
  Widget build(BuildContext context) {
    final title = recording.title ?? recording.label ?? 'Recording';
    final hasSummary = recording.summary != null;

    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(
          context,
          text: title,
          actions: [
            IconButton(
              tooltip: 'Delete recording',
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Tokens.text,
                size: 22,
              ),
              onPressed: () async {
                if (!await confirmDeleteRecording(context, recording)) return;
                store.remove(recording);
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Tokens.gutter,
              Tokens.x2,
              Tokens.gutter,
              Tokens.x10,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: Tokens.x4),
                child: Text(
                  '${dayTimeLabel(recording.startedAt)} · '
                  '${_duration(recording)}',
                  style: Tokens.caption,
                ),
              ),
              // The summary on its own at the top; everything said below it
              // in one transcript, each line keeping its time.
              if (hasSummary) ...[
                _Bubble(
                  heading: 'Summary',
                  child: Text(
                    recording.summary!,
                    style: Tokens.body.copyWith(
                        fontSize: 15, color: Tokens.text, height: 1.55),
                  ),
                ),
                const SizedBox(height: Tokens.x3),
              ],
              _Bubble(
                heading: 'Transcript',
                child: recording.utterances.isEmpty
                    ? Text('Nothing was picked up.',
                        style: Tokens.body.copyWith(color: Tokens.textFaint))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < recording.utterances.length; i++)
                            Padding(
                              padding: EdgeInsets.only(
                                  top: i == 0 ? 0 : Tokens.x3),
                              child: _Line(utterance: recording.utterances[i]),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _duration(Recording recording) {
    final minutes = recording.endedAt.difference(recording.startedAt).inMinutes;
    if (minutes < 1) return 'under a minute';
    if (minutes == 1) return '1 minute';
    if (minutes < 60) return '$minutes minutes';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest m';
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.heading, required this.child});

  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Surface(
      radius: 20,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading.toUpperCase(), style: Tokens.label),
          const SizedBox(height: Tokens.x2),
          child,
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.utterance});

  final RecordingUtterance utterance;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(timeLabel(utterance.at), style: Tokens.caption),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              if (utterance.fromOrdi)
                TextSpan(
                  text: 'Ordi  ',
                  style: Tokens.bodyStrong.copyWith(fontSize: 14.5),
                ),
              TextSpan(text: utterance.text),
            ]),
            style: Tokens.body.copyWith(
              fontSize: 14.5,
              color: utterance.fromOrdi ? Tokens.textSoft : Tokens.text,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
