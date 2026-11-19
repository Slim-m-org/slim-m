// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real render of [StartupScreen] at the one size it now actually launches
/// into: [DesktopWindowShell.splashWindowSize], the small splash window
/// decision 0012's superseding section describes - so a change here can be
/// looked at rather than guessed about. This screen no longer renders inside
/// the full desktop window (that was the pre-superseding design this file
/// used to snapshot at 1280x720 and 1920x1080): the splash is now a fixed
/// small size regardless of the real window's own saved geometry, so there
/// is exactly one size to check: the lattice-to-mark sequence at three
/// moments with real bootstrap phases, and an update prompt.
///
/// Rendered through `flutter test`'s software rasteriser, never a real
/// window - the same "no display involved" category decision 0012 itself
/// names as safe to automate, unlike raising the built binary on this
/// machine's own display.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';

import '../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  final splashSize = Size(
    DesktopWindowShell.splashWindowSize.width,
    DesktopWindowShell.splashWindowSize.height,
  );

  Future<void> frame(WidgetTester tester, Widget app) =>
      tester.pumpWidget(RepaintBoundary(key: snapshotBoundary, child: app));

  Future<void> sized(WidgetTester tester) async {
    tester.view.physicalSize = splashSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // Mid-ripple, mid-mark and settled, so the whole lattice-to-mark sequence can be looked at frame by frame.
  for (final at in const [250, 550, 1100]) {
    testWidgets('startup screen at ${at}ms with real phases', (tester) async {
      await sized(tester);
      await frame(tester, const _Dark(status: 'Restoring session'));
      await tester.pump(Duration(milliseconds: at ~/ 3));
      await frame(tester, const _Dark(status: 'Loading preferences'));
      await tester.pump(Duration(milliseconds: at ~/ 3));
      await frame(tester, const _Dark(status: 'Connecting'));
      await tester.pump(Duration(milliseconds: at - 2 * (at ~/ 3)));

      await writeSnapshot(tester, 'startup-screen-splash-${at}ms');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('startup screen settled under a light system theme', (
    tester,
  ) async {
    await sized(tester);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await frame(tester, const StartupApp(status: 'Connecting'));
    await tester.pump(const Duration(milliseconds: 1100));

    await writeSnapshot(tester, 'startup-screen-splash-light');
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup screen with an update prompt', (tester) async {
    await sized(tester);
    await frame(
      tester,
      StartupApp(
        themeMode: ThemeMode.dark,
        prompt: StartupPrompt(
          title: 'Version 0.106.0 is available',
          detail:
              'Update with your package manager: sudo dnf upgrade slim-m-client',
          primaryLabel: 'Get update',
          onPrimary: () {},
          secondaryLabel: 'Not now',
          onSecondary: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1100));

    await writeSnapshot(tester, 'startup-screen-splash-prompt');
    expect(tester.takeException(), isNull);
  });
}

/// The splash as a dark system theme shows it, which these frames have always been.
class _Dark extends StatelessWidget {
  const _Dark({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) =>
      StartupApp(status: status, themeMode: ThemeMode.dark);
}
