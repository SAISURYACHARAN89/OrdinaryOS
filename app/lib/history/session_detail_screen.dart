import 'package:flutter/material.dart';

import '../models/conversation_log.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';

/// The exchange-by-exchange detail behind one entry in the History list.
class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final ConversationSession session;

  @override
  Widget build(BuildContext context) {
    final fallbackTitle = session.entries.length == 1
        ? '1 exchange'
        : '${session.entries.length} exchanges';

    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: screenBar(context, text: session.title ?? fallbackTitle),
        body: SafeArea(
          top: false,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
                Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
            itemCount: session.entries.length + (session.summary != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (session.summary != null && index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Tokens.x4),
                  child: Surface(
                    radius: 20,
                    padding: const EdgeInsets.all(Tokens.x4),
                    child: Text(session.summary!,
                        style: Tokens.body.copyWith(fontSize: 14.5, height: 1.55)),
                  ),
                );
              }
              final entry =
                  session.entries[index - (session.summary != null ? 1 : 0)];
              return Padding(
                padding: const EdgeInsets.only(bottom: Tokens.x3 - 2),
                child: Surface(
                  radius: 20,
                  padding: const EdgeInsets.all(Tokens.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(timeLabel(entry.at), style: Tokens.caption),
                      const SizedBox(height: Tokens.x1),
                      Text(entry.question,
                          style: Tokens.heading.copyWith(fontSize: 16)),
                      const SizedBox(height: Tokens.x1),
                      Text(entry.answer, style: Tokens.body.copyWith(fontSize: 14, height: 1.5)),
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
}
