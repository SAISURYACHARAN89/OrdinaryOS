import 'package:flutter/material.dart';

import '../models/conversation_log.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';
import 'session_detail_screen.dart';

/// The full conversation record — reached from the small icon on Conversate
/// rather than its own row on the dashboard.
///
/// Shows one row per *session* (a sitting close together in time, see
/// `ConversationLog.sessionGap`) rather than one row per exchange — a
/// half-hour of back-and-forth used to show up as a dozen separate top-level
/// entries with nothing tying them together. Tapping a session opens the
/// actual exchange-by-exchange detail; this list is the table of contents.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.log});

  final ConversationLog log;

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: 'History'),
        body: AnimatedBuilder(
          animation: log,
          builder: (context, _) {
            final sessions = log.sessions;
            if (sessions.isEmpty) {
              return const EmptyNote(
                "Nothing here yet — conversations with Ordi will show "
                "up once you've had one.",
              );
            }
            return SafeArea(
              top: false,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                    Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
                    child: Surface(
                      radius: Tokens.rMedium,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionDetailScreen(session: session),
                        ),
                      ),
                      padding: const EdgeInsets.all(Tokens.x4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  session.displayTitle,
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
                              '${dayTimeLabel(session.startedAt)} · ${session.countLabel}',
                              style: Tokens.caption),
                          if (session.summary != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              session.summary!,
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
}
