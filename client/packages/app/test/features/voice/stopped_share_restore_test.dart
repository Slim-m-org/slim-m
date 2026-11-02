// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share the viewer stopped watching is not lost: a slim row above the stage
/// offers it back, the sharer's tile says it is hidden, and a share that
/// direct play stands in for is left alone.
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
import 'package:slimm_app/src/features/voice/widgets/stopped_shares_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

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

final _watchButton = find.widgetWithText(AppButton, 'Watch');

// A fixed run of frames long enough for a menu or fade to finish, without waiting on a ticker that may never stop.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  test('a held or ended share is not offered back', () {
    const watch = ShareWatchState(stopped: {'a', 'b', 'c'}, held: {'b'});
    final offered = stoppedSharers([
      _p('a'),
      _p('b'),
      _p('c', sharing: false),
      _p('d'),
    ], watch);
    expect([for (final p in offered) p.identity], ['a']);
  });

  testWidgets('a stopped share gets a row above the stage that restores it', (
    tester,
  ) async {
    final h = await _call(tester, [_p('a'), _p('b')]);
    expect(find.text('a is sharing'), findsNothing);

    _watch(h).stop('a');
    await _settle(tester);

    final row = find.text('a is sharing');
    expect(row, findsOneWidget);
    final stage = find.byKey(const Key('fake-share-view-b'));
    expect(
      tester.getRect(row).bottom,
      lessThanOrEqualTo(tester.getRect(stage).top),
      reason: 'a banner pushes the stage down instead of covering it',
    );
    expect(tester.takeException(), isNull);

    await tester.tap(_watchButton);
    await _settle(tester);
    expect(find.text('a is sharing'), findsNothing);
    expect(find.byKey(const Key('fake-share-view-a')), findsOneWidget);
    expect(_watch(h).state.stopped, isEmpty);
    await _leave(h);
  });

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
    expect(_watchButton, findsNothing);
    expect(find.byKey(hiddenShareBadgeKey), findsNothing);
    await _leave(h);
  });

  testWidgets('three hidden shares fold into one row that restores them all', (
    tester,
  ) async {
    final h = await _call(tester, [_p('a'), _p('b'), _p('c'), _p('d')]);
    for (final id in ['a', 'b', 'c']) {
      _watch(h).stop(id);
    }
    await _settle(tester);
    expect(find.text('3 shares are hidden'), findsOneWidget);
    expect(_watchButton, findsNothing);

    await tester.tap(find.widgetWithText(AppButton, 'Watch all'));
    await _settle(tester);
    expect(find.text('3 shares are hidden'), findsNothing);
    expect(_watch(h).state.stopped, isEmpty);
    await _leave(h);
  });

  testWidgets('on a phone the row fits and its button is a touch target', (
    tester,
  ) async {
    final h = await _call(tester, [
      _p('a-very-long-sharer-name-that-cannot-fit-on-one-line'),
      _p('b'),
    ], size: const Size(390, 844));
    _watch(h).stop('a-very-long-sharer-name-that-cannot-fit-on-one-line');
    await _settle(tester);

    expect(tester.takeException(), isNull);
    final button = tester.getRect(_watchButton);
    expect(button.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(button.right, lessThanOrEqualTo(390));
    await _leave(h);
  });
}
