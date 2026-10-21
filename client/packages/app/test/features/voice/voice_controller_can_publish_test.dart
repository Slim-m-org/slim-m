// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The token's publish right reaches the session, so a listen-only join never
/// readies a microphone it cannot use.
library;

import 'package:flutter_test/flutter_test.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  for (final canPublish in [true, false]) {
    test(
      'a token with can_publish $canPublish is handed to the session',
      () async {
        final session = FakeSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(canPublish: canPublish),
        );

        await controller.join('channel-1');

        expect(session.joinedAbleToPublish, canPublish);
      },
    );
  }
}
