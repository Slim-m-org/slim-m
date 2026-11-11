// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage with several screen shares: the grid at three widths,
/// focusing one share, and stopping then resuming watching.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_call_controls.dart'
    show CallControls;
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
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
const _ultrawide = Size(2400, 900);
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

Finder _tile(String id) => find.byKey(ValueKey('share:$id'));

Key _stage(String id) => ValueKey('share-stage-$id');

double _area(WidgetTester tester, Finder f) {
  final r = tester.getRect(f);
  return r.width * r.height;
}

void main() {
  testWidgets('opening the chat beside a share relays the call out once', (
    tester,
  ) async {
    final call = await _connected(tester, [
      _p('a'),
      _p('me', sharing: false, local: true),
    ], const Size(1600, 900));
    var dockBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is CallControls) dockBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    call.harness.container.read(voiceChatPaneVisibleProvider.notifier).state =
        true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;
    // A width tween rebuilt the dock on each of its dozen frames, which stuttered the whole app.
    expect(dockBuilds, lessThanOrEqualTo(2));
    await _leave(call);
  });

  testWidgets('a speaking flip rebuilds only the talker\'s tile', (
    tester,
  ) async {
    VoiceParticipant who(String id, {bool speaking = false}) =>
        VoiceParticipant(
          identity: id,
          name: id,
          isLocal: id == 'me',
          isSpeaking: speaking,
          isMuted: false,
          isScreenSharing: id == 'a',
        );
    final call = await _connected(tester, [
      who('a'),
      who('b'),
      who('me'),
    ], const Size(1600, 900));
    final rebuilt = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) {
      final name = element.widget.runtimeType.toString();
      rebuilt[name] = (rebuilt[name] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 0; i < 6; i++) {
      call.session.emitParticipants([
        who('a'),
        who('b', speaking: i.isEven),
        who('me'),
      ]);
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;
    // Each flip once rebuilt the whole stage, share and header included (about 220 widgets).
    expect(rebuilt['ScreenShareStage'], isNull);
    expect(rebuilt['CallStageLayout'], isNull);
    expect(rebuilt['CallParticipantTile'] ?? 0, lessThanOrEqualTo(6));
    await _leave(call);
  });

  testWidgets('your own share is a calm tile with a Stop sharing button', (
    tester,
  ) async {
    final call = await _connected(tester, [
      _p('me', local: true),
      _p('a', sharing: false),
    ], _wide);
    expect(find.byKey(const Key('fake-share-view-me')), findsNothing);
    expect(find.text('You are sharing your screen'), findsOneWidget);
    final stop = tester.getRect(find.text('Stop sharing'));
    expect(tester.getRect(_tile('me')).contains(stop.center), isTrue);
    await _leave(call);
  });

  testWidgets('one share keeps the single stage with no strip', (tester) async {
    final call = await _connected(tester, [
      _p('a'),
      _p('b', sharing: false),
    ], _wide);
    expect(find.byType(ScreenShareStage), findsOneWidget);
    expect(find.byTooltip('Focus this share'), findsNothing);
    await _leave(call);
  });

  for (final (name, size) in [
    ('wide', _wide),
    ('ultrawide', _ultrawide),
    ('medium', _medium),
    ('phone', _phone),
    ('small phone', const Size(360, 640)),
  ]) {
    testWidgets('six shares at $name width show six tiles that keep 16:9', (
      tester,
    ) async {
      final call = await _connected(tester, [
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) _p(id),
      ], size);
      expect(find.byType(ScreenShareStage), findsNWidgets(6));
      final screen = Offset.zero & size;
      final rects = [
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f'])
          tester.getRect(_tile(id)),
      ];
      for (final r in rects) {
        expect(screen.contains(r.topLeft), isTrue, reason: '$r');
        expect(screen.contains(r.bottomRight), isTrue, reason: '$r');
        expect(r.width / r.height, closeTo(16 / 9, 0.02));
      }
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          final inter = rects[i].intersect(rects[j]);
          expect(inter.width > 0.5 && inter.height > 0.5, isFalse);
        }
      }
      expect(tester.takeException(), isNull);
      await _leave(call);
    });
  }

  testWidgets('the pinned share is the largest tile', (tester) async {
    final call = await _connected(tester, [
      for (final id in ['a', 'b', 'c']) _p(id),
    ], _wide);
    for (final id in ['b', 'c']) {
      expect(
        _area(tester, _tile('a')),
        greaterThanOrEqualTo(_area(tester, _tile(id))),
      );
    }
    await _leave(call);
  });

  testWidgets('tapping a smaller share pins it', (tester) async {
    final call = await _connected(tester, [
      for (final id in ['a', 'b', 'c']) _p(id),
    ], _wide);
    expect(_area(tester, _tile('c')), lessThan(_area(tester, _tile('a'))));
    await tester.tapAt(tester.getCenter(_tile('c')));
    await tester.pumpAndSettle();
    expect(
      _area(tester, _tile('c')),
      greaterThanOrEqualTo(_area(tester, _tile('a'))),
    );
    await _leave(call);
  });

  testWidgets('the share menu pins one and the pin keeps its video mounted', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byKey(_stage('b')));
    await tester.tap(find.text("Focus b's screen"));
    await tester.pumpAndSettle();
    expect(
      _area(tester, _tile('b')),
      greaterThanOrEqualTo(_area(tester, _tile('a'))),
    );
    expect(find.byKey(const Key('fake-share-view-b')), findsOneWidget);
    expect(find.byKey(const Key('fake-share-view-a')), findsOneWidget);
    await _leave(call);
  });

  testWidgets(
    'stop watching removes the share and blocks it, and the tile menu offers it back',
    (tester) async {
      final call = await _connected(tester, [_p('a'), _p('b')], _wide);

      await rightClickMenu(tester, find.byType(ScreenShareStage).first);
      await tester.tap(find.text('Stop watching'));
      await tester.pumpAndSettle();
      expect(find.byType(ScreenShareStage), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-a')), findsNothing);
      expect(call.session.videoBlocked.last, {'screen:a'});
      expect(find.byKey(hiddenShareBadgeKey), findsOneWidget);

      await rightClickMenu(tester, find.byKey(hiddenShareBadgeKey));
      await tester.tap(find.text('Watch stream'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('fake-share-view-a')), findsOneWidget);
      expect(call.session.videoBlocked.last, isEmpty);
      expect(find.byKey(hiddenShareBadgeKey), findsNothing);
      await _leave(call);
    },
  );

  testWidgets('stopping the only share leaves the grid and a hidden tile', (
    tester,
  ) async {
    final call = await _connected(tester, [
      _p('a'),
      _p('me', local: true, sharing: false),
    ], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage));
    await tester.tap(find.text('Stop watching'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsNothing);
    expect(find.byKey(hiddenShareBadgeKey), findsOneWidget);
    await _leave(call);
  });

  testWidgets('on a phone Stop watching is in the long-press menu', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _phone);
    await longPressMenu(tester, _tile('a'));
    await tester.tap(find.text('Stop watching'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsOneWidget);
    expect(find.byKey(hiddenShareBadgeKey), findsOneWidget);
    await _leave(call);
  });

  testWidgets('a share that ends and starts again is offered again', (
    tester,
  ) async {
    final call = await _connected(tester, [_p('a'), _p('b')], _wide);
    await rightClickMenu(tester, find.byType(ScreenShareStage).first);
    await tester.tap(find.text('Stop watching'));
    await tester.pumpAndSettle();

    call.session.emitParticipants([_p('a', sharing: false), _p('b')]);
    await tester.pumpAndSettle();
    expect(find.byKey(hiddenShareBadgeKey), findsNothing);

    call.session.emitParticipants([_p('a'), _p('b')]);
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareStage), findsNWidgets(2));
    await _leave(call);
  });
}
