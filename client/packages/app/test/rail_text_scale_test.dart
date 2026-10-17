// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop rail at a large text scale and with an unnamed call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pumpRail(
  WidgetTester tester, {
  double scale = 1,
  VoiceState? call,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      if (call != null)
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, call),
        ),
    ],
  );
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
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
  return fixture;
}

Finder _railKeycaps() => find.descendant(
  of: find.byType(ChannelRail),
  matching: find.byType(AppKbd),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the Ctrl+K keycaps show at normal scale', (tester) async {
    final fixture = await _pumpRail(tester);
    expect(_railKeycaps(), findsWidgets);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('the keycaps drop out at 200 percent so Search keeps its room', (
    tester,
  ) async {
    final fixture = await _pumpRail(tester, scale: 2);
    expect(_railKeycaps(), findsNothing);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a call whose channel is not loaded reads "In a call"', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = await _pumpRail(
      tester,
      call: const VoiceState(
        channelId: 'c-missing',
        state: VoiceSessionState.connected,
      ),
    );
    final summary = find.byType(RailCallSummary);
    expect(summary, findsOneWidget);
    expect(
      find.descendant(of: summary, matching: find.text('In a call')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(summary).label,
      isNot(contains('call in')),
      reason: 'no "Back to the call in a call"',
    );
    semantics.dispose();
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
