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
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              Tokens.gutter,
              Tokens.x2,
              Tokens.gutter,
              Tokens.x10,
            ),
            itemCount: recording.utterances.length + (hasSummary ? 1 : 0) + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Tokens.x4),
                  child: Text(
                    '${dayTimeLabel(recording.startedAt)} · '
                    '${_duration(recording)}',
                    style: Tokens.caption,
                  ),
                );
              }
              if (hasSummary && index == 1) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Tokens.x4),
                  child: Surface(
                    radius: 20,
                    padding: const EdgeInsets.all(Tokens.x4),
                    child: Text(
                      recording.summary!,
                      style: Tokens.body.copyWith(fontSize: 14.5, height: 1.55),
                    ),
                  ),
                );
              }

              final utterance =
                  recording.utterances[index - 1 - (hasSummary ? 1 : 0)];
              return Padding(
                padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
                child: Surface(
                  radius: 20,
                  padding: const EdgeInsets.all(Tokens.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        utterance.fromOrdi
                            ? '${timeLabel(utterance.at)} · ORDI'
                            : timeLabel(utterance.at),
                        style: Tokens.caption,
                      ),
                      const SizedBox(height: Tokens.x1),
                      Text(
                        utterance.text,
                        style: Tokens.body.copyWith(
                          fontSize: 14.5,
                          color: Tokens.text,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
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
