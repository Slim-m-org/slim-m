// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared window that closes ends the share and says so, instead of freezing for everyone watching.
library;

import 'package:flutter_test/flutter_test.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('the shared window closing stops the share and shows why', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    await controller.setScreenShare(true, sourceId: 'window:7');
    expect(controller.state.screenSharing, isTrue);

    session.sourceLost.add('window:7');
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.screenSharing, isFalse);
    expect(controller.state.error, contains('closed'));
  });
}
