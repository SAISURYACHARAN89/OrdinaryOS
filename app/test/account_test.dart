import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/models/pairing.dart';
import 'package:ordi/account/sign_in_flow.dart';
import 'package:ordi/main.dart';
import 'package:ordi/models/account.dart';
import 'package:ordi/session.dart';
import 'package:ordi_audio/ordi_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the account backend: the same replies, held in memory.
class FakeBackend {
  FakeBackend({this.left = 25, this.unlimited = false, this.heardLeft});

  int left;

  /// Sentences the server will still let it hear today; null for a server
  /// from before the listening ceiling.
  int? heardLeft;
  final List<Map<String, Object?>> heardReports = [];
  final Set<String> heardCounted = {};
  bool unlimited;
  bool owner = true;
  bool offline = false;
  bool phonesFull = false;
  String code = '123456';
  int refreshes = 0;
  int session = 0;
  final List<String> calls = [];
  final Set<String> counted = {};

  Map<String, Object?> get _credits => {
        'tier': unlimited ? 'unlimited' : 'free',
        'dailyLimit': unlimited ? null : 25,
        'creditsLeft': unlimited ? null : left,
        if (heardLeft != null && !unlimited) 'heardLimit': 150,
        if (heardLeft != null && !unlimited) 'heardLeft': heardLeft,
        'resetsAt': '2100-01-01T00:00:00.000Z',
      };

  Map<String, dynamic> _signedIn() => {
        'accessToken': 'access-${++session}',
        'refreshToken': 'refresh-$session',
        'expiresInSeconds': 900,
        'account': {'email': 'owner@x.com', 'name': 'Asha'},
        'entitlement': {'tier': owner ? (unlimited ? 'unlimited' : 'free') : 'none', 'reason': owner ? 'owner' : 'no_purchase'},
        'credits': owner ? _credits : null,
        'devices': [
          {'id': 'd1', 'name': 'iPhone', 'platform': 'ios', 'current': true},
        ],
      };

  Future<ApiReply> call(String method, String path,
      {Map<String, Object?>? body, String? bearer}) async {
    calls.add('$method $path');
    if (offline) throw AccountFailure('offline', "Can't reach Ordinary.");
    switch (path) {
      case '/auth/start':
        return const ApiReply(200, {'ok': true});
      case '/auth/verify':
        if (body?['ticket'] == 'ticket-1' && body?['replaceDeviceId'] == 'old-1') {
          phonesFull = false;
          return ApiReply(200, _signedIn());
        }
        if (body?['code'] != code) {
          return const ApiReply(401, {'code': 'bad_code', 'error': 'That code is not right.', 'attemptsLeft': 4});
        }
        if (phonesFull) {
          return const ApiReply(409, {
            'code': 'device_limit',
            'error': 'Ordinary is already on 2 phones.',
            'ticket': 'ticket-1',
            'devices': [
              {'id': 'old-1', 'name': 'Old iPhone', 'platform': 'ios', 'lastSeenAt': '2026-09-01T10:00:00.000Z'},
              {'id': 'old-2', 'name': 'Android phone', 'platform': 'android'},
            ],
          });
        }
        return ApiReply(200, _signedIn());
      case '/auth/refresh':
        refreshes++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (body?['refreshToken'] != 'refresh-$session') {
          return const ApiReply(401, {'code': 'signed_out'});
        }
        return ApiReply(200, _signedIn());
      case '/usage/answer':
        if (counted.add('${body?['exchangeId']}') && !unlimited && left > 0) left--;
        return ApiReply(200, {'counted': true, ..._credits});
      case '/usage/heard':
        heardReports.add({...?body});
        if (heardCounted.add('${body?['batchId']}') && heardLeft != null) {
          final count = (body?['count'] as num?)?.toInt() ?? 0;
          heardLeft = heardLeft! - count < 0 ? 0 : heardLeft! - count;
        }
        return ApiReply(200, {'counted': true, ..._credits});
      case '/me':
        return ApiReply(200, _signedIn()..remove('accessToken')..remove('refreshToken'));
      case '/auth/signout':
      case '/me/delete':
        return const ApiReply(200, {'ok': true});
    }
    return const ApiReply(404, {});
  }
}

void main() {
  late FakeBackend backend;
  late MemoryStore secrets;
  Account make() => Account(transport: backend.call, secrets: secrets);

  // Written with the Band offered; the tests for it being hidden say so.
  setUpAll(() => Pairing.bandAvailable = true);
  tearDownAll(() => Pairing.bandAvailable = false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakeBackend();
    secrets = MemoryStore();
  });

  group('the account', () {
    test('signs in with the emailed code and keeps the sign-in for next launch',
        () async {
      final account = make();
      await account.load();
      expect(account.status, AccountStatus.signedOut);
      expect(account.installId, hasLength(32));

      await account.start('Owner@X.com ');
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      expect(account.hasAccess, isTrue);
      expect(account.email, 'owner@x.com');
      expect(account.credits?.left, 25);
      expect(account.devices.single.current, isTrue);

      // A new launch: signed in at once from what was saved, then renewed.
      final next = make();
      await next.load();
      expect(next.signedIn, isTrue);
      expect(next.installId, account.installId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.refreshes, 1);
    });

    test('a wrong code says how many tries are left', () async {
      final account = make();
      await account.load();
      await expectLater(
        account.verify(emailAddress: 'owner@x.com', code: '000000'),
        throwsA(isA<AccountFailure>()
            .having((f) => f.code, 'code', 'bad_code')
            .having((f) => f.attemptsLeft, 'attemptsLeft', 4)),
      );
      expect(account.signedIn, isFalse);
    });

    test('two requests needing a new token share one renewal', () async {
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      final tokens = await Future.wait([
        account.accessToken(force: true),
        account.accessToken(force: true),
        account.accessToken(force: true),
      ]);
      // A refresh token works once: three racing renewals would sign out.
      expect(backend.refreshes, 1);
      expect(tokens.toSet(), hasLength(1));
      expect(account.signedIn, isTrue);
    });

    test('a refused renewal signs the phone out; being offline does not',
        () async {
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');

      backend.offline = true;
      await expectLater(account.accessToken(force: true),
          throwsA(isA<AccountFailure>().having((f) => f.code, 'code', 'offline')));
      expect(account.signedIn, isTrue);

      backend.offline = false;
      backend.session = 99; // the server no longer knows this refresh token
      expect(await account.accessToken(force: true), isNull);
      expect(account.status, AccountStatus.signedOut);
      expect(await secrets.read('ordinary_refresh_token'), isNull);
    });

    test('sentences heard are counted at once and reported ten at a time', () async {
      backend = FakeBackend(heardLeft: 150);
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      // Signing in sends anything left over from before; let that finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (var i = 0; i < 9; i++) {
        await account.reportHeard();
      }
      expect(account.credits?.heardLeft, 141, reason: 'shown straight away');
      expect(backend.heardReports, isEmpty, reason: 'not a request per sentence');

      await account.reportHeard();
      expect(backend.heardReports.single['count'], 10);
      expect(backend.heardLeft, 140);
      expect(account.credits?.heardLeft, 140);
      // Listening costs no answers.
      expect(account.credits?.left, 25);
      expect(account.outOfCredits, isFalse);
    });

    test('a report that could not be sent goes again under the same id', () async {
      backend = FakeBackend(heardLeft: 150);
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      // Signing in sends anything left over from before; let that finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      backend.offline = true;
      for (var i = 0; i < 10; i++) {
        await account.reportHeard();
      }
      expect(backend.heardReports, isEmpty);
      backend.offline = false;
      // Ten more fill the next batch; the stuck one is sent first.
      for (var i = 0; i < 10; i++) {
        await account.reportHeard();
      }
      expect(backend.heardReports.first['count'], 10);
      expect(backend.heardCounted.length, backend.heardReports.length,
          reason: 'no report was counted twice');
      expect(backend.heardLeft, lessThanOrEqualTo(140));
    });

    test('running out of listening pauses Ordinary even with answers left', () async {
      backend = FakeBackend(left: 12, heardLeft: 3);
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      // Signing in sends anything left over from before; let that finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await account.reportHeard();
      await account.reportHeard();
      expect(account.outOfCredits, isFalse);
      await account.reportHeard();
      expect(account.credits?.listenedOut, isTrue);
      expect(account.credits?.spent, isFalse);
      expect(account.outOfCredits, isTrue);
      expect(backend.heardReports.single['count'], 3, reason: 'reported the moment it ran out');
    });

    test('unlimited, and a server with no ceiling, are never paused by listening', () async {
      backend = FakeBackend(unlimited: true, heardLeft: 0);
      var account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      // Signing in sends anything left over from before; let that finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (var i = 0; i < 25; i++) {
        await account.reportHeard();
      }
      expect(account.outOfCredits, isFalse);
      // Still counted, so real use can be seen.
      expect(backend.heardReports.length, 2);

      secrets = MemoryStore();
      SharedPreferences.setMockInitialValues({});
      backend = FakeBackend(); // no heardLeft at all: an older server
      account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      // Signing in sends anything left over from before; let that finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (var i = 0; i < 200; i++) {
        await account.reportHeard();
      }
      expect(account.credits?.heardLeft, isNull);
      expect(account.outOfCredits, isFalse);
    });

    test('an answer costs one credit, shown at once and confirmed by the server',
        () async {
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      await account.reportAnswer();
      expect(account.credits?.left, 24);
      expect(backend.left, 24);
      expect(account.outOfCredits, isFalse);
    });

    test('answers given offline are reported later, once each', () async {
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');

      backend.offline = true;
      await account.reportAnswer();
      await account.reportAnswer();
      expect(account.credits?.left, 23); // counted down on the phone
      expect(backend.left, 25); // the server has not heard yet

      backend.offline = false;
      await account.reportAnswer();
      expect(backend.left, 22);
      expect(backend.counted, hasLength(3));
      expect(account.credits?.left, 22);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('account_answer_queue_v1'), isEmpty);
    });

    test('unlimited is never out of credits', () async {
      backend = FakeBackend(unlimited: true);
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      for (var i = 0; i < 30; i++) {
        await account.reportAnswer();
      }
      expect(account.tier, 'unlimited');
      expect(account.outOfCredits, isFalse);
    });

    test('signing out forgets the sign-in but keeps this install\'s id',
        () async {
      final account = make();
      await account.load();
      await account.verify(emailAddress: 'owner@x.com', code: '123456');
      final id = account.installId;
      await account.signOut();
      expect(account.status, AccountStatus.signedOut);
      expect(account.email, isNull);
      expect(await secrets.read('ordinary_refresh_token'), isNull);
      expect(await secrets.read('ordinary_install_id'), id);
    });
  });

  group('the sign-in screens', () {
    Future<void> pumpFlow(WidgetTester tester, Account account) async {
      await tester.pumpWidget(MaterialApp(
        home: AnimatedBuilder(
          animation: account,
          builder: (context, _) => account.signedIn
              ? (account.hasAccess
                  ? const Scaffold(body: Text('inside'))
                  : NoAccessScreen(account: account))
              : SignInFlow(account: account),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('email, then code, then in', (tester) async {
      final account = make();
      await tester.runAsync(account.load);
      await pumpFlow(tester, account);

      expect(find.text('Sign in'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(backend.calls, isEmpty);

      await tester.enterText(find.byType(TextField), 'owner@x.com');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('Send again in'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '000000');
      await tester.pumpAndSettle();
      expect(find.text('That code is not right. 4 tries left.'), findsOneWidget);

      // The sixth digit submits by itself.
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2)); // let the resend timer end
    });

    testWidgets('a third phone chooses one to sign out', (tester) async {
      backend.phonesFull = true;
      final account = make();
      await tester.runAsync(account.load);
      await pumpFlow(tester, account);

      await tester.enterText(find.byType(TextField), 'owner@x.com');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();

      expect(find.text('Already on 2 phones'), findsOneWidget);
      expect(find.text('Old iPhone'), findsOneWidget);
      expect(find.text('Last used 1 Sep'), findsOneWidget);
      expect(find.text('Android phone'), findsOneWidget);

      await tester.tap(find.text('Old iPhone'));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('someone with no order is told so, and can switch email',
        (tester) async {
      backend.owner = false;
      final account = make();
      await tester.runAsync(account.load);
      await tester.runAsync(
          () => account.verify(emailAddress: 'owner@x.com', code: '123456'));
      await pumpFlow(tester, account);

      expect(find.text('Ordinary is for owners'), findsOneWidget);
      expect(find.textContaining("couldn't find an Ordinary order for owner@x.com"),
          findsOneWidget);
      expect(find.text('Get an Ordinary'), findsOneWidget);

      // The order arrives; checking again lets them in.
      backend.owner = true;
      await tester.tap(find.text('I have ordered — check again'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);
    });
  });

  group('the app, gated', () {
    const audioChannel = MethodChannel('ordi/audio');
    const eventChannel = EventChannel('ordi/audio/events');
    late List<String> audioCalls;

    setUp(() {
      audioCalls = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, (call) async {
        audioCalls.add(call.method);
        return switch (call.method) {
          'requestPermission' => true,
          'isRunning' => true,
          'stats' => <String, Object?>{'taps': audioCalls.length},
          'takePendingQuestion' => <String, Object?>{'text': '', 'intentRanAt': 0.0},
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
          eventChannel, MockStreamHandler.inline(onListen: (_, _) {}));
      OrdiAudio.resetForTesting();
      OrdiBackend.stub =
          () async => const SessionToken(token: 't', model: 'm');
      OrdiBackend.insightsStub = (_) async => null;
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(audioChannel, null);
      messenger.setMockStreamHandler(eventChannel, null);
      OrdiBackend.stub = null;
      OrdiBackend.insightsStub = null;
      Account.factoryForTesting = null;
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
        'someone who finished setup before accounts existed must sign in, and '
        'nothing listens until they do', (tester) async {
      // Setup already done on this phone; no sign-in saved.
      SharedPreferences.setMockInitialValues(
          {
        'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
        'ai_consent_v1': '{"allowed":true}',
      });
      final account = make();
      Account.factoryForTesting = () => account;

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Ordinary OS'), findsNothing);
      expect(audioCalls, isNot(contains('requestPermission')));
      expect(audioCalls, isNot(contains('connect')));

      await tester.runAsync(
          () => account.verify(emailAddress: 'owner@x.com', code: '123456'));
      await settle(tester);

      expect(find.text('Ordinary OS'), findsOneWidget);
      expect(find.text('25 left'), findsOneWidget);
      expect(audioCalls, contains('requestPermission'));
      expect(audioCalls, contains('connect'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets('signing out returns to the sign-in screen and closes the session',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {
        'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
        'ai_consent_v1': '{"allowed":true}',
      });
      final account = make();
      await tester.runAsync(() async {
        await account.load();
        await account.verify(emailAddress: 'owner@x.com', code: '123456');
      });
      Account.factoryForTesting = () => account;

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.text('Ordinary OS'), findsOneWidget);
      audioCalls.clear();

      await tester.runAsync(account.signOut);
      await settle(tester);
      expect(find.text('Sign in'), findsOneWidget);
      expect(audioCalls, contains('disconnect'));
      // Signed out means the microphone is closed too, not only the session.
      expect(audioCalls, contains('stop'));

      // …and it stays closed: the watchdog and the app coming back to the
      // front must not reopen it for someone who is not signed in.
      audioCalls.clear();
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(audioCalls, isNot(contains('start')));

      // Signing in again opens it again.
      await tester.runAsync(() => account.verify(emailAddress: 'owner@x.com', code: '123456'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
      expect(audioCalls, contains('start'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets('turning Gemini off closes the microphone, and turning it on opens it again',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
        'ai_consent_v1': '{"allowed":true}',
      });
      final account = make();
      await tester.runAsync(() async {
        await account.load();
        await account.verify(emailAddress: 'owner@x.com', code: '123456');
      });
      Account.factoryForTesting = () => account;

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      audioCalls.clear();

      // Withdrawn in Settings, as the switch does it.
      await tester.tap(find.text('O'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Answer with Google Gemini'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(audioCalls, containsAll(['disconnect', 'stop']));

      audioCalls.clear();
      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(audioCalls, contains('start'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets("the day's listening running out ends the session and says when it resumes",
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
        'ai_consent_v1': '{"allowed":true}',
      });
      // Plenty of answers left; almost no listening.
      backend = FakeBackend(left: 12, heardLeft: 2);
      final account = make();
      await tester.runAsync(() async {
        await account.load();
        await account.verify(emailAddress: 'owner@x.com', code: '123456');
      });
      Account.factoryForTesting = () => account;

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.text('12 left'), findsOneWidget);
      audioCalls.clear();

      // Two overheard sentences: no answer given, no credit used.
      await tester.runAsync(account.reportHeard);
      await settle(tester);
      expect(audioCalls, isNot(contains('disconnect')));
      await tester.runAsync(account.reportHeard);
      await settle(tester);

      expect(audioCalls, contains('disconnect'));
      expect(find.text('Resting'), findsOneWidget);
      expect(find.textContaining("Ordinary has done today's listening"), findsOneWidget);
      // The server was told at once, without waiting to fill a batch.
      expect(backend.heardReports.single['count'], 2);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets('the last credit ends the session and says when it refills',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {
        'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
        'ai_consent_v1': '{"allowed":true}',
      });
      backend = FakeBackend(left: 1);
      final account = make();
      await tester.runAsync(() async {
        await account.load();
        await account.verify(emailAddress: 'owner@x.com', code: '123456');
      });
      Account.factoryForTesting = () => account;

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.text('1 left'), findsOneWidget);
      audioCalls.clear();

      await tester.runAsync(account.reportAnswer);
      await settle(tester);

      expect(find.text('0 left'), findsOneWidget);
      expect(audioCalls, contains('disconnect'));
      expect(find.textContaining("You've used today's 25 answers"), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });
  });
}
