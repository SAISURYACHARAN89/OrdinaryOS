import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/models/ai_consent.dart';
import 'package:ordi/models/ordi_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiConsent', () {
    test('has no answer until one is given, and that is not a yes', () async {
      SharedPreferences.setMockInitialValues({});
      final consent = AiConsent();
      await consent.load();
      expect(consent.loaded, isTrue);
      expect(consent.decided, isFalse);
      expect(consent.allowed, isFalse);
    });

    test('remembers a yes, a no, and a change of mind', () async {
      SharedPreferences.setMockInitialValues({});
      final consent = AiConsent();
      await consent.load();
      await consent.answer(allow: true);

      final next = AiConsent();
      await next.load();
      expect(next.decided, isTrue);
      expect(next.allowed, isTrue);

      await next.answer(allow: false);
      final later = AiConsent();
      await later.load();
      expect(later.decided, isTrue);
      expect(later.allowed, isFalse);
    });

    test('an unreadable answer is asked again rather than taken as a yes', () async {
      SharedPreferences.setMockInitialValues({'ai_consent_v1': 'not json'});
      final consent = AiConsent();
      await consent.load();
      expect(consent.decided, isFalse);
      expect(consent.allowed, isFalse);
    });
  });

  group('OrdiSettings', () {
    test('starts on the default voice with no language preference', () {
      SharedPreferences.setMockInitialValues({});
      final settings = OrdiSettings();
      expect(settings.voice, OrdiSettings.defaultVoice);
      expect(settings.language, isEmpty);
    });

    test('choices survive a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final first = OrdiSettings()
        ..setVoice(ordiVoices.firstWhere((v) => v.name == 'Puck'))
        ..setLanguage('Tamil');
      await Future<void>.delayed(Duration.zero);

      final second = OrdiSettings();
      await second.load();
      expect(second.chosen.name, 'Puck');
      expect(second.language, 'Tamil');
      first.dispose();
      second.dispose();
    });

    test('a voice or language it does not know is ignored on load', () async {
      SharedPreferences.setMockInitialValues({
        'ordi_settings_v1': '{"voice":"Nobody","language":"Klingon"}',
      });
      final settings = OrdiSettings();
      await settings.load();
      expect(settings.voice, OrdiSettings.defaultVoice);
      expect(settings.language, isEmpty);
    });

    test('a corrupt blob falls back to the defaults', () async {
      SharedPreferences.setMockInitialValues({'ordi_settings_v1': 'not json'});
      final settings = OrdiSettings();
      await settings.load();
      expect(settings.voice, OrdiSettings.defaultVoice);
    });

    test('six voices: three male, three female, one of each Indian', () {
      expect(ordiVoices, hasLength(6));
      expect(ordiVoices.where((v) => v.male), hasLength(3));
      expect(ordiVoices.where((v) => !v.male), hasLength(3));
      expect(ordiVoices.where((v) => v.male && v.accent == 'indian'), hasLength(1));
      expect(ordiVoices.where((v) => !v.male && v.accent == 'indian'), hasLength(1));
      final keys = ordiVoices.map((v) => v.key).toList();
      expect(keys.toSet(), hasLength(6));
      expect(keys, contains(OrdiSettings.defaultVoice));
    });

    test('an Indian-accent voice sends its accent, a plain one does not', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = OrdiSettings();
      settings.setVoice(ordiVoices.firstWhere((v) => v.name == 'Sulafat'));
      expect(settings.chosen.name, 'Sulafat');
      expect(settings.chosen.accent, 'indian');
      settings.setVoice(ordiVoices.firstWhere((v) => v.name == 'Kore'));
      expect(settings.chosen.accent, isEmpty);
    });

    test('a voice saved when thirty were offered still resolves', () async {
      SharedPreferences.setMockInitialValues({
        'ordi_settings_v1': '{"voice":"Kore","language":""}',
      });
      final settings = OrdiSettings();
      await settings.load();
      expect(settings.chosen.name, 'Kore');
    });
  });
}
