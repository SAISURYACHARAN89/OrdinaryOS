import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ai_consent.dart';
import '../session.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// Served by our own backend, so it always matches this version of the app.
const privacyUrl = '${OrdiBackend.baseUrl}/privacy';

/// What goes to Google, said plainly. One list, used by the first-run screen
/// and by Settings, so the two can never disagree.
const aiDataSent = [
  (
    'Your voice',
    'What the microphone hears while Ordinary is listening, which can '
        'include other people nearby, and anything you type to it.',
  ),
  (
    'What a question needs',
    'Only when you ask about them: your reminders, your recording notes, '
        'the names on your speed dial or of a contact you ask it to call, '
        'and short passages from PDFs you added.',
  ),
  (
    'Your settings',
    'The voice and language you chose, and the time where you are.',
  ),
];

/// Asks, before anything is sent, whether Ordinary may use Google Gemini.
class AiConsentScreen extends StatelessWidget {
  const AiConsentScreen({super.key, required this.consent});

  final AiConsent consent;

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          // The explanation scrolls; the choice stays in view under it, so
          // nobody has to hunt for the way to say yes or no.
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Tokens.gutter, Tokens.x4, Tokens.gutter, Tokens.x4),
                  children: [
                    const SizedBox(height: Tokens.x6),
                    Text('Ordinary answers with ${AiConsent.service}',
                        style: Tokens.display),
                    const SizedBox(height: Tokens.x3),
                    Text(
                      'To answer you, Ordinary sends the following to '
                      '${AiConsent.provider}, a separate company, through its '
                      'Gemini service. Nothing is sent until you allow it.',
                      style: Tokens.body.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: Tokens.x5),
                    const AiDataList(),
                    const SizedBox(height: Tokens.x4),
                    Text(
                      '${AiConsent.provider} uses this to produce the answer, '
                      'under its own terms. Ordinary does not keep your '
                      'audio. Your phone numbers, your full contact list and '
                      'your whole documents are never sent. You can turn this '
                      'off at any time in Settings.',
                      style: Tokens.caption.copyWith(fontSize: 13),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await launchUrl(Uri.parse(privacyUrl),
                              mode: LaunchMode.externalApplication);
                        } catch (_) {}
                      },
                      child: Text(
                        'Read the privacy policy',
                        style:
                            Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkButton(
                      label: 'Allow and continue',
                      onPressed: () => consent.answer(allow: true),
                    ),
                    const SizedBox(height: Tokens.x2),
                    TextButton(
                      onPressed: () => consent.answer(allow: false),
                      child: Text(
                        'Not now',
                        style:
                            Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
                      ),
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
}

/// The list of what is sent.
class AiDataList extends StatelessWidget {
  const AiDataList({super.key});

  @override
  Widget build(BuildContext context) {
    return Surface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, (title, detail)) in aiDataSent.indexed) ...[
            if (i > 0) const SizedBox(height: Tokens.x3),
            Text(title, style: Tokens.bodyStrong),
            const SizedBox(height: 2),
            Text(detail, style: Tokens.caption.copyWith(fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
