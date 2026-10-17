// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone the per-participant volume opens as one sheet: one title, the
/// slider straight in the sheet (no card inside it), and normal easy to find.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_audio_controls.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_volume_popover.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_controller_harness.dart';

Future<VoiceController> _controller() async {
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  return harness.controllerWith(FakeSession(), voiceApi());
}

void main() {
  testWidgets(
    'the phone sheet has one title and the control fills its content width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = await _controller();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showParticipantVolumePopover(
                  context,
                  identity: 'user-1',
                  name: 'Jellyfin',
                  controller: controller,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Volume for Jellyfin'), findsOneWidget);
      expect(
        find.text('Volume for you'),
        findsNothing,
        reason: 'one title, not two',
      );
      final row = tester.getRect(find.byType(ParticipantVolumeControl));
      expect(row.width, closeTo(390 - 2 * AppSpacing.s16, 1));
      expect(
        row.height,
        lessThan(AppSizes.rowTouch * 1.5),
        reason: 'one row at the touch floor, not stacked',
      );
      final bordered = find.ancestor(
        of: find.byType(AppSlider),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null,
        ),
      );
      expect(bordered, findsNothing, reason: 'no card nested inside the sheet');
    },
  );

  testWidgets('a drag that ends near normal lands on normal', (tester) async {
    final controller = await _controller();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ParticipantVolumeControl(
            identity: 'user-1',
            controller: controller,
          ),
        ),
      ),
    );
    tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(97);
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(controller.volumeFor('user-1'), 1.0);
    tester.widget<AppSlider>(find.byType(AppSlider)).onChanged!(90);
    await tester.pump();
    expect(
      find.text('90%'),
      findsOneWidget,
      reason: 'far enough away is left alone',
    );
  });
}
