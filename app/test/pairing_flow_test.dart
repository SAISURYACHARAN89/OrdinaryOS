import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ordi/models/pairing.dart';
import 'package:ordi/pairing/pairing_flow.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Lets the radar animate without pumpAndSettle, which never settles.
  Future<void> wait(WidgetTester tester, int ms) async {
    for (var t = 0; t < ms; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('simulated setup finds and connects SM03, then the second '
      'device', (tester) async {
    expect(Pairing.simulated, isTrue);
    final pairing = Pairing();
    await tester.pumpWidget(MaterialApp(home: PairingFlow(pairing: pairing)));

    await tester.tap(find.text('Continue'));
    await wait(tester, 400);
    expect(find.text('SM03'), findsNothing);

    // The Audios show up after a moment of looking.
    await wait(tester, 2600);
    expect(find.text('SM03'), findsOneWidget);
    expect(find.text('Next'), findsNothing);

    await tester.tap(find.text('SM03'));
    await wait(tester, 300);
    expect(find.text('Connecting to SM03…'), findsOneWidget);

    await wait(tester, 2400);
    expect(find.text('Connected'), findsWidgets);
    expect(pairing.audiosConnected, isTrue);
    expect(pairing.audiosName, 'SM03');

    // Connecting no longer moves on by itself; Next does.
    await tester.tap(find.text('Next'));
    await wait(tester, 3000);
    await tester.tap(find.text('Band'));
    await wait(tester, 2600);
    await tester.tap(find.text('Next'));
    await wait(tester, 400);

    expect(pairing.bandConnected, isTrue);
    expect(pairing.bandName, 'Band');
    expect(find.text("You're all set"), findsOneWidget);
    expect(find.text('Paired'), findsNWidgets(2));
  });
}
