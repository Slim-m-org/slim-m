// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The session's automatic input threshold over a fake native gate.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _FakeGate {
  double levelDb = -60;
  final configured = <double>[];

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'getInputGate') return {'levelDb': levelDb, 'voice': false};
    if (method == 'setInputGate') {
      configured.add((args! as Map)['thresholdDb'] as double);
    }
    return null;
  }
}

/// An unmuted microphone, which is what gives the gate's readings a consumer.
class _OpenMic implements MicPort {
  @override
  bool get open => true;

  @override
  Stream<void> get lost => const Stream.empty();

  @override
  Future<double?> senderLevelDb() async => null;

  @override
  void onRoomEvent(lk.RoomEvent event) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('automatic mode moves the native threshold and reports it', () {
    fakeAsync((async) {
      final fake = _FakeGate();
      final monitor = InputGateMonitor(invoke: fake.invoke, supported: true);
      final session = VoiceSession(inputGate: monitor, micPort: _OpenMic());
      final reported = <double>[];
      session.autoInputThresholds.listen(reported.add);

      session.setInputGate(enabled: true, thresholdDb: -50);
      session.setAutoInputThreshold(true);
      monitor.start(() {});
      async.elapse(const Duration(seconds: 90));

      expect(reported, isNotEmpty);
      expect(session.inputThresholdDb, closeTo(-48, 1));
      expect(fake.configured.last, session.inputThresholdDb);
    });
  });

  test('a manual threshold is ignored while automatic, and kept after', () {
    fakeAsync((async) {
      final fake = _FakeGate();
      final monitor = InputGateMonitor(invoke: fake.invoke, supported: true);
      final session = VoiceSession(inputGate: monitor, micPort: _OpenMic());

      session.setInputGate(enabled: true, thresholdDb: -50);
      session.setAutoInputThreshold(true);
      session.setInputGate(enabled: true, thresholdDb: -20);
      expect(session.inputThresholdDb, -50);

      monitor.start(() {});
      async.elapse(const Duration(seconds: 90));
      final last = session.inputThresholdDb;
      session.setAutoInputThreshold(false);
      async.elapse(const Duration(seconds: 30));
      expect(session.inputThresholdDb, last);

      session.setInputGate(enabled: true, thresholdDb: -30);
      expect(session.inputThresholdDb, -30);
    });
  });
}
