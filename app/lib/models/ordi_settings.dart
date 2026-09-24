import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One choice in the voice list: one of Gemini's prebuilt voices, optionally
/// with a speaking style asked for on top of it.
///
/// Six are offered rather than all thirty — three male, three female, one of
/// each with an Indian accent. Every prebuilt voice is trained on the same
/// (American) accent, so an accent cannot be picked from the voice list; it is
/// requested in the prompt, which is what [accent] carries to the backend.
class OrdiVoice {
  const OrdiVoice(
    this.name,
    this.trait, {
    required this.male,
    this.accent = '',
  });

  /// The voice name the backend pins into the session token.
  final String name;
  final String trait;
  final bool male;

  /// A style the backend layers on top, or empty for the voice as it is.
  final String accent;

  /// What is stored and compared. Two entries can share a [name] only if they
  /// differ in [accent], so the pair is the identity.
  String get key => accent.isEmpty ? name : '$name+$accent';

  String get description =>
      '${male ? 'Male' : 'Female'}${accent.isEmpty ? '' : ' · Indian accent'}';
}

const List<OrdiVoice> ordiVoices = [
  OrdiVoice('Charon', 'Informative', male: true),
  OrdiVoice('Puck', 'Upbeat', male: true),
  OrdiVoice('Orus', 'Firm', male: true, accent: 'indian'),
  OrdiVoice('Kore', 'Firm', male: false),
  OrdiVoice('Aoede', 'Breezy', male: false),
  OrdiVoice('Sulafat', 'Warm', male: false, accent: 'indian'),
];

/// A language the person can say they mainly speak. [name] is what the
/// backend puts in the prompt; [native] is how it is shown, in its own script.
///
/// It is only a hint: Ordi follows whatever it actually hears, in any language,
/// so leaving this on Automatic is the right choice for most people.
class OrdiLanguage {
  const OrdiLanguage(this.name, this.native);

  final String name;
  final String native;
}

const List<OrdiLanguage> ordiLanguages = [
  OrdiLanguage('English', 'English'),
  OrdiLanguage('Hindi', 'हिन्दी'),
  OrdiLanguage('Bengali', 'বাংলা'),
  OrdiLanguage('Telugu', 'తెలుగు'),
  OrdiLanguage('Marathi', 'मराठी'),
  OrdiLanguage('Tamil', 'தமிழ்'),
  OrdiLanguage('Gujarati', 'ગુજરાતી'),
  OrdiLanguage('Urdu', 'اردو'),
  OrdiLanguage('Kannada', 'ಕನ್ನಡ'),
  OrdiLanguage('Odia', 'ଓଡ଼ିଆ'),
  OrdiLanguage('Malayalam', 'മലയാളം'),
  OrdiLanguage('Punjabi', 'ਪੰਜਾਬੀ'),
];

/// What the person has chosen in Settings. Sent with every session request, so
/// a change takes effect on the next session — see `OrdiController.restart`.
class OrdiSettings extends ChangeNotifier {
  static const _prefsKey = 'ordi_settings_v1';
  static const defaultVoice = 'Charon';

  /// The chosen [OrdiVoice.key].
  String _voice = defaultVoice;

  /// Empty means Automatic: no preference, follow what is heard.
  String _language = '';

  String get voice => _voice;
  String get language => _language;

  OrdiVoice get chosen =>
      ordiVoices.firstWhere((v) => v.key == _voice, orElse: () => ordiVoices.first);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final voice = map['voice'] as String?;
      final language = map['language'] as String?;
      if (voice != null) {
        // A choice saved when all thirty voices were offered maps to the same
        // voice if it is still on the list, and to the default if not.
        for (final v in ordiVoices) {
          if (v.key == voice || (v.accent.isEmpty && v.name == voice)) {
            _voice = v.key;
          }
        }
      }
      if (language != null &&
          (language.isEmpty || ordiLanguages.any((l) => l.name == language))) {
        _language = language;
      }
      notifyListeners();
    } catch (_) {
      // A corrupt blob is not worth failing over; the defaults are fine.
    }
  }

  void setVoice(OrdiVoice voice) {
    if (_voice == voice.key) return;
    _voice = voice.key;
    notifyListeners();
    _persist();
  }

  void setLanguage(String language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({'voice': _voice, 'language': _language}),
    );
  }
}
