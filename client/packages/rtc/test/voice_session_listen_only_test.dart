// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A token that cannot publish never has the microphone opened for push to talk.
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/session_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CountingMic mic;

  setUp(() => mic = CountingMic());

  Future<void> joinMuted(bool canPublish) async {
    final session = instantSession(mic: mic);
    addTearDown(session.dispose);
    await session.setKeepMicReady(true);
    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: false,
      canPublish: canPublish,
    );
    await session.setKeepMicReady(true);
  }

  test('a push-to-talk join that may publish readies the microphone', () async {
    await joinMuted(true);

    expect(mic.reopens, 1);
  });

  test('a listen-only join leaves the capture device closed', () async {
    await joinMuted(false);

    expect(mic.reopens, 0);
  });
}
