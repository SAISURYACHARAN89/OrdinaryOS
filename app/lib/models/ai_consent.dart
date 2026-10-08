import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether this person has agreed to what Ordinary sends to Google's Gemini.
///
/// Ordinary answers by sending speech, and sometimes things from the app, to
/// a company that is not us. That needs a plain explanation and a yes before
/// the first byte goes — not a paragraph in a policy. Until there is a yes,
/// no microphone is opened and no session is started. The answer is kept on
/// the phone and can be changed in Settings.
class AiConsent extends ChangeNotifier {
  static const _prefsKey = 'ai_consent_v1';

  /// Who processes it, as shown to the person.
  static const provider = 'Google';
  static const service = 'Google Gemini';

  bool loaded = false;

  /// True once they have answered, either way.
  bool decided = false;

  /// True when they said yes. Nothing is sent without it.
  bool allowed = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        allowed = map['allowed'] as bool? ?? false;
        decided = true;
      } catch (_) {
        // An unreadable answer is no answer: ask again.
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> answer({required bool allow}) async {
    decided = true;
    allowed = allow;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'allowed': allow,
        'at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }
}
