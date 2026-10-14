// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-person volume control is one compact row at popover and phone
/// widths, and never wraps its label or value onto a second line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/participant_audio_controls.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart' show VoiceHarness, FakeSession, voiceApi;

const _widths = {'popover': 300.0, 'phone': 360.0};

void main() {
  for (final entry in _widths.entries) {
    for (final showLabel in [true, false]) {
      testWidgets('volume control stays one line at ${entry.key} width, '
          'label $showLabel, moved off normal', (tester) async {
        final harness = VoiceHarness();
        addTearDown(harness.dispose);
        final controller = harness.controllerWith(FakeSession(), voiceApi());
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: entry.value - 24,
                  child: ParticipantVolumeControl(
                    identity: 'user-1',
                    controller: controller,
                    showLabel: showLabel,
                  ),
                ),
              ),
            ),
          ),
        );
        tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(200);
        await tester.pump();

        final height = tester
            .getSize(find.byType(ParticipantVolumeControl))
            .height;
        expect(height, lessThanOrEqualTo(AppSizes.controlSm + 8));
        final value = tester.getSize(find.text('200%')).height;
        expect(value, lessThan(20), reason: 'the value did not wrap');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final dark in [true, false]) {
    for (final entry in _widths.entries) {
      testWidgets('snapshot ${entry.key} ${dark ? 'dark' : 'light'}', (
        tester,
      ) async {
        tester.view.physicalSize = Size(entry.value, 120);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final harness = VoiceHarness();
        addTearDown(harness.dispose);
        final controller = harness.controllerWith(FakeSession(), voiceApi());
        final tokens = dark ? AppTokens.dark : AppTokens.light;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(
              dark ? Brightness.dark : Brightness.light,
              tokens,
            ),
            home: RepaintBoundary(
              key: snapshotBoundary,
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  child: ParticipantVolumeControl(
                    identity: 'user-1',
                    controller: controller,
                  ),
                ),
              ),
            ),
          ),
        );
        tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(150);
        await tester.pump();
        await writeSnapshot(
          tester,
          'volume-row-${entry.key}-${dark ? 'dark' : 'light'}',
        );
      });
    }
  }
}
