// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share tile carries no corner buttons: pop out, stream volume, hide and
/// full screen live in its context menu, reached by right-click, long-press
/// or the menu key, and a hidden stream gets "Show stream" on the person.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/popout_window.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_call_menu.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/menu_gestures.dart';
import 'voice_controller_harness.dart';

const _items = [
  'Pop out stream',
  'Stream volume',
  'Hide stream',
  'Full screen',
];

Future<({ProviderContainer container, List<String> calls})> _pumpStage(
  WidgetTester tester,
) async {
  final calls = <String>[];
  final container = ProviderContainer(
    overrides: [popOutSupportedProvider.overrideWithValue(true)],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 360,
            child: ScreenShareStage(
              sharerName: 'Ada',
              popOutIdentity: 'u-ada',
              onStreamVolume: (_) => calls.add('volume'),
              onStopWatching: () => calls.add('hide'),
              onExpand: () => calls.add('fullscreen'),
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    ),
  );
  return (container: container, calls: calls);
}

List<String> _labels(WidgetTester tester) => [
  for (final i in tester.widgetList<AppMenuItem>(find.byType(AppMenuItem)))
    i.label,
];

void main() {
  testWidgets('the tile has no corner buttons', (tester) async {
    await _pumpStage(tester);
    expect(find.byIcon(AppIcons.expand), findsNothing);
    expect(find.byIcon(AppIcons.popOut), findsNothing);
    expect(find.byIcon(AppIcons.tileHide), findsNothing);
    expect(find.byIcon(AppIcons.speaker), findsNothing);
  });

  final gestures = <String, Future<void> Function(WidgetTester)>{
    'right-click': (t) => rightClickMenu(t, find.byType(ScreenShareStage)),
    'long-press': (t) => longPressMenu(t, find.byType(ScreenShareStage)),
    'the menu key': (t) => keyboardMenu(t),
  };
  for (final entry in gestures.entries) {
    testWidgets('${entry.key} lists the stream actions and each one acts', (
      tester,
    ) async {
      final rig = await _pumpStage(tester);
      await entry.value(tester);
      expect(_labels(tester), _items);

      await tester.tap(find.text('Pop out stream'));
      await tester.pumpAndSettle();
      expect(rig.container.read(popOutFeedProvider)?.identity, 'u-ada');

      for (final (label, call) in [
        ('Stream volume', 'volume'),
        ('Hide stream', 'hide'),
        ('Full screen', 'fullscreen'),
      ]) {
        await entry.value(tester);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(rig.calls.last, call);
      }
    });
  }

  testWidgets('a hidden stream is shown again from the person\'s menu', (
    tester,
  ) async {
    const ada = VoiceParticipant(
      identity: 'u-ada',
      name: 'Ada',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: true,
    );
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
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    session.emitParticipants(const [ada]);
    await tester.pump();
    harness.container.read(shareWatchProvider.notifier).stop('u-ada');

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
                  participant: ada,
                  close: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Show stream'), findsOneWidget);
    expect(find.text('Hide stream'), findsNothing);
    expect(session.videoBlocked.last, isNotEmpty, reason: 'hidden is blocked');

    await tester.tap(find.text('Show stream'));
    await tester.pump();
    expect(harness.container.read(shareWatchProvider).stopped, isEmpty);
    expect(session.videoBlocked.last, isEmpty, reason: 'shown is unblocked');
    await controller.leave();
  });
}
