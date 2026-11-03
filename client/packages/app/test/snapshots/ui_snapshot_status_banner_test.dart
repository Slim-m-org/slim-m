// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every [StatusBanner] severity over a call-stage-like surface, at desktop and
/// phone width in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 420), 'phone': Size(390, 520)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('status banners at ${entry.key} ($theme)', (tester) async {
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
                    spacing: AppSpacing.s12,
                    children: [
                      const StatusBanner(
                        message:
                            'Your microphone went silent. Switched to Desk mic.',
                        icon: AppIcons.mic,
                        onDismiss: _noop,
                      ),
                      const StatusBanner(
                        severity: BannerSeverity.success,
                        message: 'Copied the invite link.',
                      ),
                      const StatusBanner(
                        severity: BannerSeverity.warning,
                        icon: AppIcons.retry,
                        message: 'Reconnecting to the call.',
                      ),
                      StatusBanner(
                        severity: BannerSeverity.error,
                        message:
                            'Windows is blocking the microphone. Allow it in Settings, then rejoin the call.',
                        action: AppButton(
                          size: AppButtonSize.sm,
                          label: 'Open settings',
                          onPressed: () {},
                        ),
                      ),
                      StatusBanner(
                        sticky: true,
                        icon: AppIcons.tileHide,
                        message: 'Jellyfin is sharing',
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
        await writeSnapshot(tester, 'status-banners-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}

void _noop() {}
