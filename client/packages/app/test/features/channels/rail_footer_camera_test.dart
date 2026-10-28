// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile footer can turn the camera on during a call, the same as the
/// call's own controls (owner request: no way to do it from the sidebar).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import '../voice/voice_controller_harness.dart';

class _CameraController extends FixedVoiceController {
  _CameraController(super.ref, super.fixed);

  int toggles = 0;

  @override
  Future<void> toggleCamera() async {
    toggles++;
    state = state.copyWith(cameraEnabled: !state.cameraEnabled);
  }
}

Future<({_CameraController controller, Future<void> Function() end})> _pump(
  WidgetTester tester,
  VoiceState voice,
) async {
  late _CameraController controller;
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => controller = _CameraController(ref, voice),
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

  testWidgets('the footer turns the camera on and off during a call', (
    tester,
  ) async {
    final rig = await _pump(tester, inCall);

    await tester.tap(find.bySemanticsLabel('Turn on camera'));
    await tester.pump();
    expect(rig.controller.toggles, 1);
    expect(find.bySemanticsLabel('Turn off camera'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Turn off camera'));
    await tester.pump();
    expect(rig.controller.toggles, 2);
    expect(find.bySemanticsLabel('Turn on camera'), findsOneWidget);
    await rig.end();
  });

  testWidgets('outside a call the footer has no camera button', (tester) async {
    final rig = await _pump(tester, const VoiceState());
    expect(find.bySemanticsLabel('Turn on camera'), findsNothing);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
    await rig.end();
  });

  testWidgets('a listen-only call shows the camera but cannot turn it on', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      const VoiceState(
        channelId: 'c-main',
        state: VoiceSessionState.connected,
        canPublish: false,
      ),
    );
    await tester.tap(find.bySemanticsLabel('Turn on camera'));
    await tester.pump();
    expect(rig.controller.toggles, 0);
    await rig.end();
  });
}
