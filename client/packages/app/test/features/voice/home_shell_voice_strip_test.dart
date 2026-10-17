// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the collapsed voice strip actually reaches the screen.
///
/// It was built (`VoiceStripIndicator`) and never placed anywhere in the
/// shell, so a call left running while the user read a different channel
/// showed no sign of itself at all. These drive the real shell, on the real
/// routes, rather than the widget in isolation, because that gap was
/// invisible to any test that only ever built the widget directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

/// Pumps the real shell at [location] with the voice controller pinned to
/// [voice], asserts whether the strip shows, and tears down before
/// returning: the shell's debounced providers (the member roster keep-alive,
/// the read marker) leave a pending timer that fails the test if it outlives
/// the widget tree instead of being disposed first.
Future<void> _expectStrip(
  WidgetTester tester,
  String location, {
  required VoiceState voice,
  required bool visible,
  Size size = const Size(390, 844),
  // The rail folds a call elsewhere into RailCallSummary, not a second strip.
  Type indicator = VoiceStripIndicator,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter(location),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));

  expect(find.byType(indicator), visible ? findsOneWidget : findsNothing);

  await teardownFixture(tester, fixture.container, fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  const inMainCall = VoiceState(
    channelId: 'c-main',
    state: VoiceSessionState.connected,
  );

  testWidgets(
    'a call connected elsewhere shows the strip on a different channel',
    (tester) async {
      await _expectStrip(
        tester,
        '/channels/c-general',
        voice: inMainCall,
        visible: true,
      );
    },
  );

  testWidgets(
    'the channel the call belongs to does not repeat it in a strip too',
    (tester) async {
      await _expectStrip(
        tester,
        '/channels/c-main',
        voice: inMainCall,
        visible: false,
      );
    },
  );

  testWidgets('no call at all shows no strip anywhere', (tester) async {
    await _expectStrip(
      tester,
      '/channels/c-general',
      voice: const VoiceState(),
      visible: false,
    );
  });

  group('wide layout, rail beside the conversation', () {
    const wide = Size(1400, 880);

    testWidgets(
      "the rail's footer folds in a call summary for a call elsewhere",
      (tester) async {
        await _expectStrip(
          tester,
          '/channels/c-general',
          voice: inMainCall,
          visible: true,
          size: wide,
          indicator: RailCallSummary,
        );
      },
    );

    testWidgets('the footer hides the call summary while viewing it', (
      tester,
    ) async {
      await _expectStrip(
        tester,
        '/channels/c-main',
        voice: inMainCall,
        visible: false,
        size: wide,
        indicator: RailCallSummary,
      );
    });
  });
}
