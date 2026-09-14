import 'package:flutter/material.dart';

import '../models/conversation_log.dart';
import '../ui/glass.dart';
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
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(session.title ?? fallbackTitle, style: Tokens.heading),
          centerTitle: true,
        ),
        body: SafeArea(
          top: false,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
                Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x10),
            itemCount: session.entries.length + (session.summary != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (session.summary != null && index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Tokens.x5),
                  child: Text(session.summary!, style: Tokens.body),
                );
              }
              final entry =
                  session.entries[index - (session.summary != null ? 1 : 0)];
              return Padding(
                padding: const EdgeInsets.only(bottom: Tokens.x3),
                child: GlassSurface(
                  radius: Tokens.rMedium,
                  padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.x4, vertical: Tokens.x3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(timeLabel(entry.at), style: Tokens.caption),
                      const SizedBox(height: Tokens.x1),
                      Text(entry.question, style: Tokens.heading),
                      const SizedBox(height: Tokens.x1),
                      Text(entry.answer, style: Tokens.body),
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
