// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hide camera: a per-person choice from the participant menu that stops
/// receiving their camera, shows their avatar tile instead, and is remembered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_call_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

Future<(VoiceHarness, FakeSession, VoiceController)> _call(
  WidgetTester tester,
) async {
  SharedPreferences.setMockInitialValues({});
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      membersProvider.overrideWith((ref) async => const <api.UserProfile>[]),
    ],
  );
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
  return (harness, session, controller);
}

Future<List<String>> _menuLabels(
  WidgetTester tester,
  VoiceHarness harness, {
  bool withFullscreen = true,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => AppMenu(
              width: 240,
              children: participantCallMenuItems(
                context,
                ref,
                participant: harness.container
                    .read(voiceControllerProvider)
                    .participants
                    .first,
                close: () {},
                withFullscreen: withFullscreen,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return [
    for (final i in tester.widgetList<AppMenuItem>(find.byType(AppMenuItem)))
      i.label,
  ];
}

void main() {
  testWidgets('a canvas leaves out the route-opening full screen rows', (
    tester,
  ) async {
    final (harness, _, controller) = await _call(tester);
    expect(await _menuLabels(tester, harness), contains('Camera full screen'));
    expect(
      await _menuLabels(tester, harness, withFullscreen: false),
      isNot(contains('Camera full screen')),
    );
    await controller.leave();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Hide camera blocks the track, reads as off, and Show undoes it',
    (tester) async {
      final (harness, session, controller) = await _call(tester);
      expect(await _menuLabels(tester, harness), contains('Hide camera'));
      expect(
        pickMiniPlayerFeed(controller.state.participants)?.kind,
        FeedKind.camera,
      );

      await tester.tap(find.text('Hide camera'));
      await tester.pump();
      expect(controller.state.participants.single.isCameraOn, isFalse);
      expect(session.videoBlocked.last, {'camera:u-ada'});
      expect(pickMiniPlayerFeed(controller.state.participants), isNull);
      expect(await _menuLabels(tester, harness), contains('Show camera'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('slimm.voice.hidden_cameras'), ['u-ada']);

      // A roster update from the call must not bring the camera back.
      session.emitParticipants(const [_ada]);
      await tester.pump();
      expect(controller.state.participants.single.isCameraOn, isFalse);

      await tester.tap(find.text('Show camera'));
      await tester.pump();
      expect(controller.state.participants.single.isCameraOn, isTrue);
      expect(session.videoBlocked.last, isEmpty);
      expect(prefs.getStringList('slimm.voice.hidden_cameras'), isEmpty);
      await controller.leave();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('the choice is remembered and re-applied when a call connects', (
    tester,
  ) async {
    final (harness, session, controller) = await _call(tester);
    await controller.cameras.setCameraHidden('u-ada', true);
    await controller.leave();
    await tester.pumpAndSettle();
    session.videoBlocked.clear();

    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    session.emitParticipants(const [_ada]);
    await tester.pump();
    expect(session.videoBlocked.last, {'camera:u-ada'});
    expect(controller.state.participants.single.isCameraOn, isFalse);
    expect(
      harness.container.read(voiceControllerProvider).participants,
      isNotEmpty,
    );
    await controller.leave();
    await tester.pumpAndSettle();
  });

  testWidgets('hiding a camera keeps a hidden share blocked too', (
    tester,
  ) async {
    final (_, session, controller) = await _call(tester);
    controller.cameras.setVideoBlocked({'screen:u-bob'});
    await controller.cameras.setCameraHidden('u-ada', true);
    expect(session.videoBlocked.last, {'screen:u-bob', 'camera:u-ada'});
    await controller.leave();
    await tester.pumpAndSettle();
  });
}
