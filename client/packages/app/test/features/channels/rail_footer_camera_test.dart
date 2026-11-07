// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile footer is a secondary call control: mic and deafen while in a
/// call, nothing out of one, and the camera left to the call dock (owner,
/// 2026-11-07: keep just mic, headphones and settings).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import '../voice/voice_controller_harness.dart';

Future<({FixedVoiceController controller, Future<void> Function() end})> _pump(
  WidgetTester tester,
  VoiceState voice,
) async {
  late FixedVoiceController controller;
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => controller = FixedVoiceController(ref, voice, FakeSession()),
      ),
    ],
  );
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels'),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  fixture.container.read(voiceControllerProvider);
  return (
    controller: controller,
    end: () => teardownFixture(tester, fixture.container, fixture.db),
  );
}

void main() {
  setUpAll(loadRealFonts);

  const inCall = VoiceState(
    channelId: 'c-main',
    state: VoiceSessionState.connected,
  );

  testWidgets('in a call the footer has mic and deafen but no camera', (
    tester,
  ) async {
    final rig = await _pump(tester, inCall);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
    expect(find.bySemanticsLabel('Deafen'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('camera')), findsNothing);
    await rig.end();
  });

  testWidgets('outside a call the footer has no call controls', (tester) async {
    final rig = await _pump(tester, const VoiceState());
    expect(find.bySemanticsLabel(RegExp('camera')), findsNothing);
    expect(find.bySemanticsLabel('Mute'), findsNothing);
    expect(find.bySemanticsLabel('Deafen'), findsNothing);
    await rig.end();
  });
}
