// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Your own share fills the call stage like a viewer's does. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1; the geometry assertions always run.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';
import 'ui_snapshot_support.dart';

VoiceParticipant _p(String id, {required bool local, bool sharing = false}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isLocal: local,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: sharing,
    );

Future<Rect> _shareRect(
  WidgetTester tester, {
  required Size size,
  required bool localSharing,
  required String name,
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
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants([
    _p('me', local: true, sharing: localSharing),
    _p('them', local: false, sharing: !localSharing),
  ]);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  final view = find.byKey(
    Key(localSharing ? 'fake-share-view-me' : 'fake-share-view-them'),
  );
  final rect = tester.getRect(view);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
  await harness.container.read(voiceControllerProvider.notifier).leave();
  harness.container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  return rect;
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (label, size) in [
    ('963x1080', const Size(963, 1080)),
    ('1440x900', const Size(1440, 900)),
    ('390x844', const Size(390, 844)),
  ]) {
    for (final local in [true, false]) {
      final who = local ? 'local' : 'remote';
      testWidgets('the $who share fills the stage at $label', (tester) async {
        final rect = await _shareRect(
          tester,
          size: size,
          localSharing: local,
          name: '$who-share-$label',
        );
        expect(
          rect.width,
          greaterThan(size.width * 0.5),
          reason: 'the share uses most of the stage width, not a thumbnail',
        );
        expect(rect.width / rect.height, closeTo(16 / 9, 0.05));
      });
    }
  }
}
