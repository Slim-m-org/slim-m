// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hidden stream stays hidden through a dropped connection and the rejoin,
/// and is forgotten when the call ends.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

void main() {
  testWidgets(
    'a hidden stream survives a dropped connection and stays blocked',
    (tester) async {
      final harness = VoiceHarness();
      addTearDown(harness.dispose);
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: const SizedBox(),
        ),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      session.emitParticipants(const [_ada]);
      await tester.pump();
      final watch = harness.container.read(shareWatchProvider.notifier);
      watch.stop('u-ada');
      expect(harness.container.read(shareWatchProvider).stopped, {'u-ada'});

      session.emitParticipants(const []);
      session.emitState(VoiceSessionState.failed);
      await tester.pump();
      session.emitState(VoiceSessionState.connected);
      session.emitParticipants(const [_ada]);
      await tester.pump();
      expect(harness.container.read(shareWatchProvider).stopped, {'u-ada'});

      await controller.leave();
      await tester.pump();
      expect(harness.container.read(shareWatchProvider).stopped, isEmpty);
      expect(session.videoBlocked.last, isEmpty);
    },
  );
}
