// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How often a call reads the input gate: fast only while a meter is shown,
/// otherwise at the dead-mic watchdog rate.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _EmptyRoom extends lk.Room {
  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}
}

class _FakeMic implements MicPort {
  bool published = false;
  bool muted = true;
  final enables = <(bool, lk.AudioCaptureOptions?)>[];
  final restarts = <bool>[];

  @override
  bool get hasTrack => published;

  double? senderLevel;

  @override
  Future<double?> senderLevelDb() async => senderLevel;

  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    enables.add((enabled, options));
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async =>
      restarts.add(options.noiseSuppression);

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}

  @override
  Stream<void> get lost => const Stream.empty();

  @override
  void onRoomEvent(lk.RoomEvent event) {}

  @override
  Future<void> discard() async => published = false;
}

class _CountingGate {
  int polls = 0;

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'getInputGate') {
      polls++;
      return {'levelDb': -40.0, 'voice': false};
    }
    return null;
  }
}

const _tick = Duration(milliseconds: 2);

Future<int> _pollsIn(_CountingGate gate, Duration window) async {
  final start = gate.polls;
  await Future<void>.delayed(window);
  return gate.polls - start;
}

void main() {
  late _CountingGate gate;
  late VoiceSession session;

  setUp(() async {
    gate = _CountingGate();
    session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      micPort: _FakeMic(),
      inputGate: InputGateMonitor(
        interval: _tick,
        invoke: gate.invoke,
        supported: true,
      ),
    );
    await session.join(url: 'wss://a.invalid', token: 't');
  });

  tearDown(() => session.dispose());

  test('a call with nothing displayed polls at a twentieth of the rate',
      () async {
    final watching = await _pollsIn(gate, const Duration(milliseconds: 400));
    session.setLevelDisplayed(true);
    final displayed = await _pollsIn(gate, const Duration(milliseconds: 400));
    expect(watching, lessThan(displayed ~/ 4));
    expect(watching, greaterThan(0), reason: 'the watchdog still reads');
  });

  test('polling drops back when the meter goes away', () async {
    session.setLevelDisplayed(true);
    final displayed = await _pollsIn(gate, const Duration(milliseconds: 400));
    session.setLevelDisplayed(false);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final after = await _pollsIn(gate, const Duration(milliseconds: 400));
    expect(after, lessThan(displayed ~/ 4));
  });

  test('automatic sensitivity adapts at a fifth of the display rate', () async {
    session.setLevelDisplayed(true);
    final displayed = await _pollsIn(gate, const Duration(milliseconds: 400));
    session.setLevelDisplayed(false);
    session.setAutoInputThreshold(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final adapting = await _pollsIn(gate, const Duration(milliseconds: 400));
    expect(adapting, lessThan(displayed ~/ 2));
    expect(adapting, greaterThan(displayed ~/ 10));
  });
}
