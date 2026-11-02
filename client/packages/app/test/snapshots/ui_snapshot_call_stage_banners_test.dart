// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage's own banner widgets in the stage's stretch column, so pill
/// widths are judged where they really sit. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/local_screen_share_banner.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_reconnect_banner.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 360), 'phone': Size(390, 420)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('call stage banners at ${entry.key} ($theme)', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final dark = theme == 'dark';
        await tester.pumpWidget(
          RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark
                  ? buildTheme(Brightness.dark, AppTokens.dark)
                  : buildTheme(Brightness.light, AppTokens.light),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const VoiceReconnectBanner(),
                      const LocalScreenSharePendingBanner(),
                      const StatusBanner(
                        severity: BannerSeverity.error,
                        sticky: true,
                        message: 'Could not join the call.',
                        margin: EdgeInsets.only(top: AppSpacing.s12),
                      ),
                      StatusBanner(
                        sticky: true,
                        icon: AppIcons.tileHide,
                        message: 'Jellyfin is sharing',
                        margin: const EdgeInsets.only(top: AppSpacing.s12),
                        action: AppButton(
                          size: AppButtonSize.sm,
                          variant: AppButtonVariant.soft,
                          label: 'Watch',
                          onPressed: () {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await writeSnapshot(tester, 'call-stage-banners-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
