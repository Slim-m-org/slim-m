// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title bar's update chip: present only with an update waiting, named
/// with the version for a screen reader, inside the bar at every width, a 44
/// target on touch, and never widened by a long version string.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_chrome.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/update_available_banner.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_chip.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

ClientUpdate _update(String version) => ClientUpdate(
  version: version,
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.flatpak,
);

Future<FakeDesktopWindowPort> _pump(
  WidgetTester tester,
  double width,
  ClientUpdate? update,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final port = FakeDesktopWindowPort();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [inSessionUpdateProvider.overrideWith((ref) => update)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              TitleBar(
                port: port,
                platform: DesktopPlatform.linux,
                onRequestClose: () async {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return port;
}

void main() {
  testWidgets('no chip without an update', (tester) async {
    await _pump(tester, 1280, null);
    expect(find.byType(UpdateChip), findsOneWidget);
    expect(find.byType(AppButton), findsNothing);
  });

  for (final width in const [390.0, 800.0, 1280.0]) {
    testWidgets('chip fits the title bar at $width with a long version', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, width, _update('123456.7890123.4567890-rc.12'));

      final bar = tester.getRect(find.byType(TitleBar));
      final chip = tester.getRect(find.byType(AppButton));
      expect(bar.contains(chip.topLeft), isTrue);
      expect(bar.contains(chip.bottomRight - const Offset(0, 0.01)), isTrue);
      expect(chip.right, lessThanOrEqualTo(width));
      expect(chip.width, lessThan(140));
      if (width < kCompactWidth) {
        expect(chip.height, greaterThanOrEqualTo(AppSizes.rowTouch));
      }
      expect(
        find.bySemanticsLabel(RegExp('123456.7890123.4567890-rc.12')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  }

  testWidgets('frameless chrome shows the chip and no banner strip', (
    tester,
  ) async {
    final shell = shellFor(null, active: true, frameless: true);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWindowShellProvider.overrideWithValue(shell),
          inSessionUpdateProvider.overrideWith((ref) => _update('9.9.9')),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          builder: (context, child) => DesktopChrome(child: child!),
          home: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppCallout), findsNothing);
    expect(find.byType(UpdateAvailableBanner), findsNothing);
    expect(find.widgetWithText(AppButton, 'Update'), findsOneWidget);
  });
}
