// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fitted call stage in the real screen (decision 0114): at desktop and
/// phone sizes every camera is on screen however late it joined, six shares
/// show six tiles with no second strip, and the pinned share is the largest.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _sizes = {
  '1280x800': Size(1280, 800),
  '1920x1080': Size(1920, 1080),
  '390x844': Size(390, 844),
  '360x640': Size(360, 640),
};

VoiceParticipant _p(
  int i, {
  bool camera = false,
  bool sharing = false,
  bool local = false,
}) => VoiceParticipant(
  identity: 'u$i',
  name: 'User $i',
  isLocal: local,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: sharing,
  isCameraOn: camera,
);

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
  await tester.pump(const Duration(seconds: 1));
  return _Call(harness, session);
}

Future<void> _leave(_Call call) =>
    call.harness.container.read(voiceControllerProvider.notifier).leave();

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey(key)));

void main() {
  for (final e in _sizes.entries) {
    final size = e.value;
    final screen = Offset.zero & size;

    testWidgets('a tenth joiner with a camera is fully on screen at ${e.key}', (
      tester,
    ) async {
      final call = await _connected(tester, [
        for (var i = 0; i < 9; i++) _p(i, local: i == 0),
      ], size);
      call.session.emitParticipants([
        for (var i = 0; i < 9; i++) _p(i, local: i == 0),
        _p(9, camera: true),
      ]);
      await tester.pump(const Duration(seconds: 1));

      final cam = _rect(tester, 'cam:u9');
      expect(screen.contains(cam.topLeft), isTrue, reason: '$cam');
      expect(screen.contains(cam.bottomRight), isTrue, reason: '$cam');
      expect(cam.width, greaterThan(size.width * 0.5));
      expect(tester.takeException(), isNull);
      await _leave(call);
    });

    testWidgets('six shares show six tiles and no strip at ${e.key}', (
      tester,
    ) async {
      final call = await _connected(tester, [
        for (var i = 0; i < 6; i++) _p(i, sharing: true),
      ], size);

      expect(
        find.byWidgetPredicate((w) => w is ScreenShareStage),
        findsNWidgets(6),
      );
      expect(
        find.byWidgetPredicate((w) => w is CallParticipantTile),
        findsNothing,
      );
      final rects = [for (var i = 0; i < 6; i++) _rect(tester, 'share:u$i')];
      for (final r in rects) {
        expect(screen.contains(r.topLeft), isTrue, reason: '$r');
        expect(screen.contains(r.bottomRight), isTrue, reason: '$r');
      }
      final pinned = rects.first;
      for (final r in rects) {
        expect(
          r.width * r.height,
          lessThanOrEqualTo(pinned.width * pinned.height * 1.001),
        );
      }
      expect(tester.takeException(), isNull);
      await _leave(call);
    });

    testWidgets('shares, cameras and people fit without a gap at ${e.key}', (
      tester,
    ) async {
      final call = await _connected(tester, [
        _p(0, local: true),
        _p(1, sharing: true),
        _p(2, sharing: true),
        for (var i = 3; i < 7; i++) _p(i, camera: true),
        for (var i = 7; i < 13; i++) _p(i),
      ], size);

      final rects = [
        for (final key in ['share:u1', 'share:u2', 'cam:u3', 'cam:u6'])
          _rect(tester, key),
        for (final t
            in find
                .byWidgetPredicate((w) => w is CallParticipantTile)
                .evaluate())
          tester.getRect(find.byWidget(t.widget)),
      ];
      for (final r in rects) {
        expect(screen.contains(r.topLeft), isTrue, reason: '$r in $size');
        expect(screen.contains(r.bottomRight), isTrue, reason: '$r in $size');
      }
      final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final header = size.height * 0.35;
      expect(top, lessThan(header), reason: 'no empty band above the stage');
      expect(tester.takeException(), isNull);
      await _leave(call);
    });
  }
}
