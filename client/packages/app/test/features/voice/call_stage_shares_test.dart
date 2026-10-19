// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage with several screen shares: the grid at three widths,
/// focusing one share, and stopping then resuming watching.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/share_stage_grid.dart';
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

const _wide = Size(1200, 900);
const _medium = Size(800, 900);
const _phone = Size(390, 1400);

class _Call {
  _Call(this.harness, this.session);
  final VoiceHarness harness;
  final FakeSession session;
}

Future<_Call> _connected(
  WidgetTester tester,
  List<VoiceParticipant> participants,
  Size size,
) async {
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
  await tester.pump();
  await tester.pumpAndSettle();
  return _Call(harness, session);
}

Future<void> _leave(_Call call) =>
    call.harness.container.read(voiceControllerProvider.notifier).leave();

Finder _tile(String id) => find.byKey(ValueKey('share-tile-$id'));

void main() {
  test('columns follow the window width', () {
    expect(shareGridColumns(390, 2), 1);
    expect(shareGridColumns(599, 3), 1);
    expect(shareGridColumns(800, 2), 2);
    expect(shareGridColumns(800, 3), 2);
    expect(shareGridColumns(1200, 2), 2);
    expect(shareGridColumns(1200, 3), 3);
    expect(shareGridColumns(1200, 4), 2);
  });

  testWidgets('one share keeps the single stage with no grid', (tester) async {
    final call = await _connected(tester, [
      _p('a'),
      _p('b', sharing: false),
    ], _wide);
    expect(find.byType(ScreenShareStage), findsOneWidget);
    expect(_tile('a'), findsNothing);
    expect(find.byTooltip('Focus this share'), findsNothing);
    await _leave(call);
  });

  for (final (name, size, cols) in [
    ('wide', _wide, 3),
    ('medium', _medium, 2),
    ('phone', _phone, 1),
  ]) {
    testWidgets('three shares at $name width lay out in $cols column(s)', (
      tester,
    ) async {
      final call = await _connected(tester, [_p('a'), _p('b'), _p('c')], size);
      expect(find.byType(ScreenShareStage), findsNWidgets(3));
      final tops = {
        for (final id in ['a', 'b', 'c']) tester.getTopLeft(_tile(id)).dy,
      };
      expect(tops.length, (3 / cols).ceil());
      for (final id in ['a', 'b', 'c']) {
        final box = tester.getSize(
          find
              .descendant(of: _tile(id), matching: find.byType(AspectRatio))
              .first,
        );
        expect(box.width / box.height, closeTo(16 / 9, 0.02));
      }
      expect(tester.takeException(), isNull);
      await _leave(call);
    });

    testWidgets('two shares at $name width show both without overflow', (
      tester,
    ) async {
      final call = await _connected(tester, [_p('a'), _p('b')], size);
      expect(_tile('a'), findsOneWidget);
      expect(_tile('b'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _leave(call);
    });
  }

  testWidgets('focus enlarges one share and thumbnails the other', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage).last);
    await tester.tap(find.text("Focus b's screen"));
    await tester.pumpAndSettle();

    expect(find.byType(ScreenShareStage), findsOneWidget);
    expect(find.byKey(const ValueKey('share-thumb-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-thumb-b')), findsNothing);
    expect(find.byKey(const Key('fake-share-view-b')), findsOneWidget);

    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Show all shares'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsNWidgets(2));
    await _leave(call);
  });

  testWidgets('tapping a thumbnail moves focus to it', (tester) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage).first);
    await tester.tap(find.text("Focus a's screen"));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-thumb-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-thumb-a')), findsOneWidget);
    expect(find.byKey(const Key('fake-share-view-b')), findsOneWidget);
    await _leave(call);
  });

  testWidgets('a thumbnail takes focus from the keyboard with Enter', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage).first);
    await tester.tap(find.text("Focus a's screen"));
    await tester.pumpAndSettle();
    var tabs = 0;
    while (tabs++ < 40 &&
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<ShareThumbnail>() ==
            null) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-thumb-a')), findsOneWidget);
    expect(find.byKey(const Key('fake-share-view-b')), findsOneWidget);
    await _leave(call);
  });

  testWidgets(
    'stop watching removes the share and blocks it, with no badge to undo it',
    (tester) async {
      final call = await _connected(tester, [_p('a'), _p('b')], _wide);

      await rightClickMenu(tester, find.byType(ScreenShareStage).first);
      await tester.tap(find.text('Hide stream'));
      await tester.pumpAndSettle();
      expect(find.byType(ScreenShareStage), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-a')), findsNothing);
      expect(call.session.videoBlocked.last, {'screen:a'});
      // Owner: show it again from the person's menu, not a badge at the top.
      expect(find.text('a is sharing'), findsNothing);
      expect(find.text('Watch'), findsNothing);
      await _leave(call);
    },
  );

  testWidgets('stopping the only share leaves the grid and no badge', (
    tester,
  ) async {
    final call = await _connected(tester, [
      _p('a'),
      _p('me', local: true, sharing: false),
    ], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Hide stream'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsNothing);
    expect(find.text('a is sharing'), findsNothing);
    await _leave(call);
  });

  testWidgets('on a phone Hide stream is in the long-press menu', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _phone);
    await longPressMenu(tester, _tile('a'));
    await tester.tap(find.text('Hide stream'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsOneWidget);
    expect(find.text('a is sharing'), findsNothing);
    await _leave(call);
  });

  testWidgets('a share that ends and starts again is offered again', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage).first);
    await tester.tap(find.text('Hide stream'));
    await tester.pumpAndSettle();

    call.session.emitParticipants([_p('a', sharing: false), _p('b')]);
    await tester.pumpAndSettle();
    expect(find.text('a is sharing'), findsNothing);

    call.session.emitParticipants([_p('a'), _p('b')]);
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsNWidgets(2));
    await _leave(call);
  });
}
