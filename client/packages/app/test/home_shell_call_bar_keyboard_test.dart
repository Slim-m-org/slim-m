// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The compact call strip must not wedge itself between composer and keyboard.
///
/// Layout follows width (desktop-vs-mobile rule 6, a status row that pushes
/// content), so the compact shell branch runs on this Linux host unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets('keyboard up: composer meets the inset, strip stays reachable', (
    tester,
  ) async {
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              channelId: 'c-main',
              state: VoiceSessionState.connected,
            ),
          ),
        ),
      ],
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter('/channels/c-general'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    final strip = find.byType(VoiceStripIndicator);
    expect(strip, findsOneWidget);
    await writeSnapshot(tester, 'phone-in-call-keyboard-closed');
    expect(
      tester.getBottomLeft(strip).dy,
      closeTo(844, 60),
      reason: 'keyboard closed: the strip sits at the bottom edge',
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump(const Duration(milliseconds: 350));

    expect(strip, findsOneWidget);
    await writeSnapshot(tester, 'phone-in-call-keyboard-open');
    final composer = find.byType(Composer);
    expect(composer, findsOneWidget);
    expect(
      tester.getBottomLeft(composer).dy,
      closeTo(844 - 300, 0.5),
      reason: 'the composer sits directly on the keyboard',
    );
    expect(
      tester.getBottomLeft(strip).dy,
      lessThan(tester.getTopLeft(composer).dy),
      reason: 'the strip moved above the transcript, not between',
    );
    expect(find.byTooltip('Leave call').hitTestable(), findsOneWidget);

    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.getBottomLeft(strip).dy, closeTo(844, 60));

    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
