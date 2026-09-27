import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/session.dart';

void main() {
  late List<String> sent;

  setUp(() {
    sent = [];
    // A stub stops real network posts; the spy records what would be sent.
    OrdiBackend.stub = () async => const SessionToken(token: 't', model: 'm');
    OrdiBackend.diagSpy = sent.add;
    OrdiBackend.resetDiagForTesting();
  });

  tearDown(() {
    OrdiBackend.stub = null;
    OrdiBackend.diagSpy = null;
    OrdiBackend.diagLevelOverride = null;
    OrdiBackend.resetDiagForTesting();
  });

  test('the default build sends events, not the heartbeat or state flips', () {
    expect(OrdiBackend.diagLevel, 'events');
    OrdiBackend.diag('heartbeat', {'frames': 50});
    OrdiBackend.diag('state', 'listening');
    OrdiBackend.diag('lifecycle', 'paused');
    OrdiBackend.diag('connected');
    OrdiBackend.diag('reconnect', {'attempt': 1});
    OrdiBackend.diag('revive');
    expect(sent, ['connected', 'reconnect', 'revive']);
  });

  test('full sends everything', () {
    OrdiBackend.diagLevelOverride = 'full';
    OrdiBackend.diag('heartbeat');
    OrdiBackend.diag('state', 'idle');
    OrdiBackend.diag('connected');
    expect(sent, ['heartbeat', 'state', 'connected']);
  });

  test('off sends nothing', () {
    OrdiBackend.diagLevelOverride = 'off';
    OrdiBackend.diag('connected');
    OrdiBackend.diag('mic-failed', 'busy');
    expect(sent, isEmpty);
  });

  test('events are capped per hour, with a single throttled marker', () {
    for (var i = 0; i < OrdiBackend.eventsPerHour + 25; i++) {
      OrdiBackend.diag('reconnect', {'attempt': i});
    }
    expect(sent.where((e) => e == 'reconnect'), hasLength(OrdiBackend.eventsPerHour));
    expect(sent.where((e) => e == 'throttled'), hasLength(1));
  });
}
