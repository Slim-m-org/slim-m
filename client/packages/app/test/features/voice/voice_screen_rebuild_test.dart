// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A speaking toggle changes the roster on every flicker; only what draws it
/// (the backdrop's colour pools, a tile's ring) may rebuild, never the screen
/// or the stage.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_layout.dart';
import 'package:slimm_app/src/features/voice/widgets/lounge_backdrop.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

VoiceParticipant _bob({required bool speaking}) => VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: false,
  isSpeaking: speaking,
  isMuted: false,
  isScreenSharing: false,
  audioLevel: speaking ? 0.6 : 0,
);

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

int _rebuilds(Map<Type, int> counts, Type t) => counts[t] ?? 0;

void main() {
  testWidgets(
    'speaking changes reach the backdrop, not the stage or the screen',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final harness = VoiceHarness();
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: [
          voiceRosterProvider.overrideWith(
            (ref, channelId) =>
                const Stream<List<api.VoiceRosterParticipant>>.empty(),
          ),
          membersProvider.overrideWith((ref) async => const []),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
        ],
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
          ),
        ),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      session.emitParticipants([_me, _bob(speaking: false)]);
      await tester.pumpAndSettle();

      final counts = <Type, int>{};
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final t = element.widget.runtimeType;
        counts[t] = (counts[t] ?? 0) + 1;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var i = 0; i < 4; i++) {
        session.emitParticipants([_me, _bob(speaking: i.isEven)]);
        await tester.pump();
      }
      debugOnRebuildDirtyWidget = previous;

      expect(_rebuilds(counts, LoungeBackdrop), greaterThan(0));
      expect(_rebuilds(counts, CallStageLayout), 0);
      expect(_rebuilds(counts, VoiceScreen), 0);

      await controller.leave();
    },
  );
}
