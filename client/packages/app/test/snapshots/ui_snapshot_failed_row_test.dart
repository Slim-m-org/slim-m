// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message that could not be sent: the reason and its three ways forward on
/// one quiet line, at phone and desktop width in both themes. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts a clean layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);
  const sizes = {'phone': Size(390, 140), 'desktop': Size(900, 110)};
  for (final entry in sizes.entries) {
    testWidgets('failed row ${entry.key} (dark+light)', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Widget build(String theme) => RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: snapshotThemeData(theme),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: AppTouchTargets(
                enabled: entry.key == 'phone',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'make this channel not give me notis',
                      style: AppText.body,
                    ),
                    FailedRow(
                      onRetry: () {},
                      onEdit: () {},
                      onDiscard: () {},
                      reason:
                          'Could not send the message: you are not allowed to do that.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build('dark'));
      await tester.pumpAndSettle();
      await checkDarkThenLight(tester, build, (theme) async {
        expect(tester.takeException(), isNull);
        for (final verb in const ['Retry', 'Edit', 'Discard']) {
          expect(find.text(verb), findsOneWidget);
        }
        await writeSnapshot(tester, 'failed-row-${entry.key}-$theme');
      });
    });
  }
}
