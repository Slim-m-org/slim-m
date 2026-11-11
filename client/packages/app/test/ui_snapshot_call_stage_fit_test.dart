// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fitted call stage in the scenarios the owner approved (decision 0114).
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; the geometry always runs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/call_dock_hint.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';
import 'ui_snapshot_support.dart';

const _names = [
  'Ada',
  'Ben',
  'Cleo',
  'Dev',
  'Eli',
  'Fay',
  'Gus',
  'Hana',
  'Ivo',
  'Jun',
  'Kai',
  'Lia',
  'Max',
];

VoiceParticipant _p(
  int i, {
  bool camera = false,
  bool sharing = false,
  bool local = false,
}) => VoiceParticipant(
  identity: 'u$i',
  name: _names[i % _names.length],
  isLocal: local,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: sharing,
  isCameraOn: camera,
);

Future<void> _render(
  WidgetTester tester,
  String name,
  Size size,
  List<VoiceParticipant> who,
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
  session.emitParticipants(who);
  await tester.pump();
  final voice = harness.container.read(voiceControllerProvider.notifier);
  // ignore: invalid_use_of_protected_member
  voice.state = voice.state.copyWith(
    connectedAt: DateTime.now().subtract(const Duration(minutes: 7)),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
  await harness.container.read(voiceControllerProvider.notifier).leave();
  harness.container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(loadRealFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      micCueSeenKey: '',
      shareHintSeenKey: true,
    }),
  );

  final sixShares = [
    _p(0, local: true),
    for (var i = 1; i <= 6; i++) _p(i, sharing: true),
  ];
  final mixed = [
    _p(0, local: true),
    _p(1, sharing: true),
    _p(2, sharing: true),
    for (var i = 3; i < 7; i++) _p(i, camera: true),
    for (var i = 7; i < 13; i++) _p(i),
  ];
  final scenarios = <String, (Size, List<VoiceParticipant>)>{
    'stage-fit-1-six-shares-1280': (const Size(1280, 800), sixShares),
    'stage-fit-2-six-shares-1920': (const Size(1920, 1080), sixShares),
    'stage-fit-3-mixed-1280': (const Size(1280, 800), mixed),
    'stage-fit-4-ten-one-camera-1920': (
      const Size(1920, 1080),
      [for (var i = 0; i < 9; i++) _p(i, local: i == 0), _p(9, camera: true)],
    ),
    'stage-fit-5-phone-390': (
      const Size(390, 844),
      [
        _p(0, local: true),
        _p(1, sharing: true),
        _p(2, sharing: true),
        for (var i = 3; i < 7; i++) _p(i, camera: true),
      ],
    ),
    'stage-fit-6-phone-360x640': (const Size(360, 640), mixed),
    'stage-fit-7-own-share-360x640': (
      const Size(360, 640),
      [_p(0, local: true, sharing: true), _p(1, camera: true), _p(2)],
    ),
  };
  for (final e in scenarios.entries) {
    testWidgets('renders ${e.key}', (tester) async {
      await _render(tester, e.key, e.value.$1, e.value.$2);
    });
  }
}
