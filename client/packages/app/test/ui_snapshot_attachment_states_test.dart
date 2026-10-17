// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline image before and instead of its pixels - the loading box and the
/// failure box with Retry - alone and as gallery tiles, at phone and desktop
/// width in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1;
/// otherwise this asserts a clean layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_image_states.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';
import 'support/fake_sync.dart';

Widget _tiles(double edge, Widget Function(double? edge) box) => Wrap(
  spacing: AppSpacing.s4,
  runSpacing: AppSpacing.s4,
  children: [box(edge), box(edge)],
);

void main() {
  setUpAll(loadRealFonts);
  const sizes = {'phone': Size(390, 640), 'desktop': Size(900, 640)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('attachment states ${entry.key} ($theme)', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final dark = theme == 'dark';
        final edge = entry.key == 'phone' ? 171.0 : 188.0;
        Widget loading(double? e) => AttachmentLoadingBox(
          filename: 'photo-b.jpeg',
          width: 380,
          tileEdge: e,
        );
        Widget failed(double? e) => AttachmentFailureBox(
          filename: 'photo-b.jpeg',
          width: 380,
          tileEdge: e,
          onRetry: () {},
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              syncControllerProvider.overrideWith(NoopSyncController.new),
            ],
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(
                  dark ? Brightness.dark : Brightness.light,
                  dark ? AppTokens.dark : AppTokens.light,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('whatcha think A or B', style: AppText.body),
                        const SizedBox(height: AppSpacing.s8),
                        loading(null),
                        const SizedBox(height: AppSpacing.s8),
                        failed(null),
                        const SizedBox(height: AppSpacing.s8),
                        _tiles(edge, loading),
                        const SizedBox(height: AppSpacing.s8),
                        _tiles(edge, failed),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Retry'), findsNWidgets(3));
        await writeSnapshot(tester, 'attachment-states-${entry.key}-$theme');
      });
    }
  }
}
