// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A package-managed install cannot take the update from GitHub, so the chip
/// opens a view that says how the package manager gets it and keeps the
/// release page as a secondary "Check GitHub". Per-user installs are
/// unchanged and open the release page straight away.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/desktop/update_action.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_package_view.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../ui_snapshot_support.dart';
import 'support/fake_desktop_window_port.dart';

const _releaseUrl = 'https://example.invalid/release';

ClientUpdate _update(InstallFormat format) =>
    ClientUpdate(version: '0.99.0', releaseUrl: _releaseUrl, format: format);

Future<List<Uri>> _pump(
  WidgetTester tester,
  InstallFormat format, {
  double width = 1280,
  bool autoUpdate = false,
  Brightness brightness = Brightness.light,
}) async {
  SharedPreferences.setMockInitialValues({autoUpdateKey: autoUpdate});
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final launched = <Uri>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inSessionUpdateProvider.overrideWith((ref) => _update(format)),
        releaseLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(
          brightness,
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
        ),
        builder: (context, child) =>
            RepaintBoundary(key: snapshotBoundary, child: child),
        home: Scaffold(
          body: Column(
            children: [
              TitleBar(
                port: FakeDesktopWindowPort(),
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
  return launched;
}

Future<void> _tapChip(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(AppButton, 'Update'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rpm: chip opens the package manager view, not GitHub', (
    tester,
  ) async {
    final launched = await _pump(tester, InstallFormat.rpm);
    await _tapChip(tester);

    expect(launched, isEmpty, reason: 'no GitHub link leads the update');
    expect(find.text('Version 0.99.0 is available'), findsOneWidget);
    expect(find.text('Update with your package manager.'), findsOneWidget);
    expect(
      find.text('sudo dnf upgrade --refresh slim-m-client'),
      findsOneWidget,
    );
    expect(find.widgetWithText(AppButton, 'Get update'), findsNothing);

    await tester.tap(find.widgetWithText(AppButton, 'Check GitHub'));
    await tester.pump();
    expect(launched, [Uri.parse(_releaseUrl)]);
  });

  testWidgets('flatpak: names flatpak update and keeps Check GitHub', (
    tester,
  ) async {
    final launched = await _pump(tester, InstallFormat.flatpak);
    await _tapChip(tester);

    expect(find.text('Update with Flatpak.'), findsOneWidget);
    expect(find.text('flatpak update top.npcserver.slimm'), findsOneWidget);
    expect(find.textContaining('dnf'), findsNothing);
    await tester.tap(find.widgetWithText(AppButton, 'Check GitHub'));
    await tester.pump();
    expect(launched, [Uri.parse(_releaseUrl)]);
  });

  testWidgets('chip tooltip and semantics name the package manager', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, InstallFormat.rpm);
    expect(
      find.bySemanticsLabel('Update 0.99.0 with your package manager'),
      findsWidgets,
    );
    expect(
      find.byTooltip('Update 0.99.0 with your package manager'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('rpm that installs itself keeps restart to update', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final launched = await _pump(tester, InstallFormat.rpm, autoUpdate: true);
    await tester.pump();
    expect(find.byTooltip('Restart to update to 0.99.0'), findsOneWidget);
    expect(launched, isEmpty);
    handle.dispose();
  });

  for (final format in [InstallFormat.tarball, InstallFormat.appImage]) {
    testWidgets('$format opens the release page directly', (tester) async {
      final launched = await _pump(tester, format);
      await _tapChip(tester);
      expect(launched, [Uri.parse(_releaseUrl)]);
      expect(find.text('Check GitHub'), findsNothing);
      expect(find.byTooltip('Get update 0.99.0'), findsOneWidget);
    });
  }

  testWidgets('the view fits a phone width', (tester) async {
    await _pump(tester, InstallFormat.rpm, width: 390);
    await _tapChip(tester);
    final code = tester.getRect(
      find.text('sudo dnf upgrade --refresh slim-m-client'),
    );
    expect(code.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  test('only package-managed formats lead with the package manager', () {
    for (final format in [
      InstallFormat.rpm,
      InstallFormat.deb,
      InstallFormat.flatpak,
    ]) {
      expect(
        updateMenuAction(_update(format)),
        UpdateMenuAction.packageManager,
        reason: '$format',
      );
    }
    expect(
      updateMenuAction(_update(InstallFormat.tarball)),
      UpdateMenuAction.openRelease,
    );
    expect(
      updateMenuAction(_update(InstallFormat.unknown)),
      UpdateMenuAction.openRelease,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('snapshot ${brightness.name}', (tester) async {
      if (!writingSnapshots) return;
      await tester.runAsync(loadRealFonts);
      await _pump(tester, InstallFormat.rpm, brightness: brightness);
      await writeSnapshot(tester, 'update-chip-${brightness.name}');
      await _tapChip(tester);
      await writeSnapshot(tester, 'update-view-${brightness.name}');
    });
  }
}
