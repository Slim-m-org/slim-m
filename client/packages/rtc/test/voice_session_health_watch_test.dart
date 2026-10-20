// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The session's health watch knows our real identity and stops with the session.
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/session_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> join(dynamic session) => session.join(
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
}
