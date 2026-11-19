// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call brought back after a restart is deafened again as soon as it
/// connects, also when the app came back in the tray and draws no frames.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/fake_voice.dart';
import '../../support/window_lifecycle.dart';

void main() {
  testWidgets('a restored call is deafened again with no frame drawn', (
    tester,
  ) async {
    late FakeVoiceController voice;
    final container = ProviderContainer(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => voice = FakeVoiceController(
            ref,
            recording: true,
            joinOutcome: const VoiceState(
              state: VoiceSessionState.connecting,
              channelId: 'voice-1',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    container.read(voiceControllerProvider);
    await hideTestWindow(tester);

    var done = false;
    final rejoin = container
        .read(rejoinRestoredCallProvider)(
          CallToRestore(
            channelId: 'voice-1',
            userId: 'user-1',
            at: DateTime(2026),
            muted: false,
            deafened: true,
          ),
        )
        .then((_) => done = true);
    await tester.idle();
    expect(voice.calls, ['join:voice-1']);

    voice.connect(channelId: 'voice-1');
    await tester.idle();

    expect(voice.calls, ['join:voice-1', 'deafen']);
    expect(done, isTrue);
    await rejoin;
  });
}
