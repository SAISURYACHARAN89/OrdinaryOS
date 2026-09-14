import 'package:flutter/material.dart';

import '../models/conversation_log.dart';
import '../ui/glass.dart';
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
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text('History', style: Tokens.heading),
          centerTitle: true,
        ),
        body: AnimatedBuilder(
          animation: log,
          builder: (context, _) {
            final sessions = log.sessions;
            if (sessions.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(Tokens.x6),
                  child: Text(
                    "Nothing here yet — conversations with Ordi will show "
                    "up once you've had one.",
                    textAlign: TextAlign.center,
                    style: Tokens.body,
                  ),
                ),
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
                  final fallbackTitle = session.entries.length == 1
                      ? '1 exchange'
                      : '${session.entries.length} exchanges';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Tokens.x3),
                    child: GlassSurface(
                      radius: Tokens.rMedium,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionDetailScreen(session: session),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: Tokens.x4, vertical: Tokens.x3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  session.title ?? fallbackTitle,
                                  style: Tokens.heading,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded,
                                  color: Tokens.textFaint, size: 20),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(dayTimeLabel(session.startedAt),
                              style: Tokens.caption),
                          if (session.summary != null) ...[
                            const SizedBox(height: Tokens.x1),
                            Text(
                              session.summary!,
                              style: Tokens.body,
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
