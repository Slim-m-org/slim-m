// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's call view reads its board for the backdrop only while the
/// canvas is on, so a closed board is never asked for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/lounge_canvas_glow.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Channel _row({required bool canvas}) => Channel(
  id: 'channel-1',
  name: 'lounge',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  canvasEnabled: canvas,
  voiceEnabled: true,
);

Future<int> _boardReads(WidgetTester tester, {required bool canvas}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  var reads = 0;
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
      channelByIdProvider(
        'channel-1',
      ).overrideWith((ref) => Stream.value(_row(canvas: canvas))),
      loungeCanvasGlowProvider('channel-1').overrideWith((ref) async {
        reads++;
        return null;
      }),
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
  await tester.pump();
  await tester.pump();
  await controller.leave();
  return reads;
}

void main() {
  testWidgets('a call view with the canvas off makes no board read', (
    tester,
  ) async {
    expect(await _boardReads(tester, canvas: false), 0);
  });

  testWidgets('a call view with the canvas on reads the board', (tester) async {
    expect(await _boardReads(tester, canvas: true), greaterThan(0));
  });
}
