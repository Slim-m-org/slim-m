// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connected voice call with stubbed members and presence, shared by the
/// call header tests and their snapshots.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/canvas/canvas_bar.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../ui_snapshot_support.dart' show snapshotBoundary;
import '../voice_controller_harness.dart';

const callMe = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const callAlice = VoiceParticipant(
  identity: 'alice',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

api.UserProfile callProfile(String id, String name, {bool bot = false}) =>
    api.UserProfile(
      id: id,
      username: name.toLowerCase(),
      displayName: name,
      createdAt: 0,
      isBot: bot,
    );

class FakePresence extends PresenceController {
  FakePresence(super.ref, Map<String, api.PresenceState> seed) {
    state = seed;
  }
}

/// Everyone listed is a channel member; [online] are the ids reading online.
List<Override> callPeople(
  List<api.UserProfile> members,
  Set<String> online,
) => [
  voiceRosterProvider.overrideWith(
    (ref, channelId) => const Stream<List<api.VoiceRosterParticipant>>.empty(),
  ),
  channelMembersProvider.overrideWith((ref, channelId) async => members),
  // The real presence controller listens to live events, which would start sync against a server that is not there.
  liveEventsProvider.overrideWithValue(const Stream<api.ServerEvent>.empty()),
  presenceSeedProvider.overrideWith((ref, channelId) async {}),
  presenceControllerProvider.overrideWith(
    (ref) => FakePresence(ref, {
      for (final id in online) id: api.PresenceState.online,
    }),
  ),
  channelByIdProvider.overrideWith(
    (ref, id) => Stream.value(
      data.Channel(
        id: id,
        name: 'test-voice',
        kind: 'voice',
        createdAt: 0,
        cursor: 0,
        lastReadSeq: 0,
        mentionedSeq: 0,
        isPersonalSpace: false,
        joinMuted: false,
        position: 0,
        slowModeSeconds: 0,
      ),
    ),
  ),
];

class CallFixture {
  CallFixture(this.tester, this.harness, this.session);
  final WidgetTester tester;
  final VoiceHarness harness;
  final FakeSession session;

  Future<void> leave() =>
      harness.container.read(voiceControllerProvider.notifier).leave();

  Future<void> emit(List<VoiceParticipant> who) async {
    session.emitParticipants(who);
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

Future<CallFixture> joinCall(
  WidgetTester tester, {
  required double width,
  required List<api.UserProfile> members,
  required Set<String> online,
  bool isDm = false,
  bool dark = false,
  double height = 844,
  bool withCanvasBar = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: callPeople(members, online),
  );
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: _callBody(
              voice: VoiceScreen(channelId: 'channel-1', isDm: isDm),
              withCanvasBar: withCanvasBar && width >= kCompactWidth,
            ),
          ),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  return CallFixture(tester, harness, session);
}

/// Side by side like the real shell: the canvas pane never stacks above the stage, and a phone shows one or the other.
Widget _callBody({required Widget voice, required bool withCanvasBar}) {
  if (!withCanvasBar) return voice;
  return Row(
    children: [
      Expanded(child: voice),
      const Expanded(
        child: Column(
          children: [
            CanvasBar(channelId: 'channel-1'),
            Spacer(),
          ],
        ),
      ),
    ],
  );
}
