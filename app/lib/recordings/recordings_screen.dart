import 'package:flutter/material.dart';

import '../models/recording_store.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';
import 'recording_detail_screen.dart';

/// Everything Ordi was told to capture.
///
/// Deliberately the same shape as History, because they are the same idea seen
/// from two sides: History is what Ordi took part in, this is what it sat
/// through without speaking. Tapping one opens the full transcript.
class RecordingsScreen extends StatelessWidget {
  const RecordingsScreen({super.key, required this.store});

  final RecordingStore store;

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: 'Recordings'),
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final recordings = store.recordings;
            if (recordings.isEmpty) {
              return const EmptyNote(
                'Nothing recorded yet — say "Hey Ordi, record this '
                'conversation" and it will keep the transcript here.',
              );
            }
            return SafeArea(
              top: false,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                    Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
                itemCount: recordings.length,
                itemBuilder: (context, index) {
                  final recording = recordings[index];
                  final live = identical(recording, store.active);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
                    child: Surface(
                      radius: Tokens.rMedium,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordingDetailScreen(recording: recording),
                        ),
                      ),
                      padding: const EdgeInsets.all(Tokens.x4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (live) ...[
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Tokens.danger,
                                  ),
                                ),
                                const SizedBox(width: Tokens.x2),
                              ],
                              Expanded(
                                child: Text(
                                  _titleFor(recording),
                                  style: Tokens.heading,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded,
                                  color: Tokens.textFaint, size: 22),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${dayTimeLabel(recording.startedAt)} · '
                            '${recording.utterances.length} captured',
                            style: Tokens.caption,
                          ),
                          if (recording.summary != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              recording.summary!,
                              style: Tokens.body.copyWith(fontSize: 14),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// The summariser's title if it came back, otherwise whatever the person
  /// called it when they started it, otherwise nothing useful — so say that
  /// rather than showing an empty row.
  String _titleFor(Recording recording) =>
      recording.title ?? recording.label ?? 'Recording';
}
