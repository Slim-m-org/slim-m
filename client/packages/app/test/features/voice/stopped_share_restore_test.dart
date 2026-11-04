// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share the viewer stopped watching is not lost: the sharer's tile says it
/// is hidden and its menu (right-click, long-press) shows it again, with no
/// banner on the stage. A share that direct play stands in for is left alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/menu_gestures.dart';
import 'voice_controller_harness.dart';

VoiceParticipant _p(String id, {bool sharing = true, bool local = false}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isLocal: local,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: sharing,
    );

Future<VoiceHarness> _call(
  WidgetTester tester,
  List<VoiceParticipant> participants, {
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
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
  session.emitParticipants(participants);
  await _settle(tester);
  return harness;
}

Future<void> _leave(VoiceHarness h) =>
    h.container.read(voiceControllerProvider.notifier).leave();

ShareWatchController _watch(VoiceHarness h) =>
    h.container.read(shareWatchProvider.notifier);

// A fixed run of frames long enough for a menu or fade to finish, without waiting on a ticker that may never stop.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

typedef MenuOpener = Future<void> Function(WidgetTester, Finder);

void main() {
  for (final (label, open) in <(String, MenuOpener)>[
    ('right-click', rightClickMenu),
    ('long-press', longPressMenu),
  ]) {
    testWidgets('$label on a hidden share tile offers Watch stream', (
      tester,
    ) async {
      final h = await _call(tester, [_p('a'), _p('b')]);
      expect(find.text('a is sharing'), findsNothing);

      _watch(h).stop('a');
      await _settle(tester);
      expect(find.text('a is sharing'), findsNothing, reason: 'no banner');
      expect(find.byKey(const Key('fake-share-view-a')), findsNothing);

      await open(tester, find.byKey(hiddenShareBadgeKey));
      expect(find.text('Watch stream'), findsOneWidget);
      await tester.tap(find.text('Watch stream'));
      await _settle(tester);
      expect(find.byKey(const Key('fake-share-view-a')), findsOneWidget);
      expect(_watch(h).state.stopped, isEmpty);
      await _leave(h);
    });
  }

  testWidgets('the sharer tile shows a hidden state until it is watched', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = await _call(tester, [_p('a'), _p('b')]);
    expect(find.byKey(hiddenShareBadgeKey), findsNothing);

    _watch(h).stop('a');
    await _settle(tester);
    expect(find.byKey(hiddenShareBadgeKey), findsOneWidget);
    expect(find.byIcon(AppIcons.tileHide), findsWidgets);
    expect(
      find.bySemanticsLabel(
        RegExp('microphone on, sharing their screen, hidden'),
      ),
      findsOneWidget,
    );

    _watch(h).watch('a');
    await _settle(tester);
    expect(find.byKey(hiddenShareBadgeKey), findsNothing);
    semantics.dispose();
    await _leave(h);
  });

  testWidgets('a share direct play stands in for is left alone', (
    tester,
  ) async {
    final h = await _call(tester, [_p('a'), _p('b')]);
    _watch(h).hold('a');
    await _settle(tester);
    expect(find.text('a is sharing'), findsNothing);
    expect(find.byKey(hiddenShareBadgeKey), findsNothing);
    await _leave(h);
  });

  testWidgets('on a phone a hidden share stays reachable by long-press', (
    tester,
  ) async {
    final h = await _call(tester, [
      _p('a'),
      _p('b'),
    ], size: const Size(390, 844));
    _watch(h).stop('a');
    await _settle(tester);

    expect(tester.takeException(), isNull);
    await longPressMenu(tester, find.byKey(hiddenShareBadgeKey));
    expect(find.text('Watch stream'), findsOneWidget);
    await _leave(h);
  });
}
