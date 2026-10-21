// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The session's health watch knows our real identity and stops with the session.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/audio_stats.dart';

import 'support/session_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> join(VoiceSession session) => session.join(
        url: 'wss://a.invalid',
        token: 't',
      );

  test('the watch reads our identity from the room it joined', () async {
    final session = instantSession(mic: CountingMic(), me: 'user-7');
    addTearDown(session.dispose);

    await join(session);

    expect(session.glitchWatch.localId, 'user-7');
  });

  test('disposing a connected session stops the sampling timer', () async {
    final session = instantSession(mic: CountingMic());
    await join(session);
    final watch = session.glitchWatch;
    expect(watch.running, isTrue);

    await session.dispose();

    expect(watch.running, isFalse);
  });

  test('a join that replaces a live call ends the old call\'s health',
      () async {
    final session = instantSession(mic: CountingMic());
    addTearDown(session.dispose);
    await join(session);
    session.health.observeRemote('ann', 'Ann', _reading(0));
    session.health.observeRemote('ann', 'Ann', _reading(10));

    await join(session);

    expect(session.health.lastCall.value, isNotNull);
    expect(session.health.hasData, isFalse);
  });
}

AudioReceiveSample _reading(double seconds) => AudioReceiveSample(
      totalSamples: seconds * 48000,
      clockRate: 48000,
      concealedSamples: 0,
    );
