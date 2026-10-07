// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The too-old screen's one button does what its hint says for each install
/// format, reports a launch that did not happen, and scrolls when it does
/// not fit (decision 0025).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';
import 'package:slimm_app/src/widgets/client_too_old_gate.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

class _FailingDnf implements RpmUpdater {
  @override
  Future<RpmUpdateResult> apply({String? currentVersion}) async =>
      const RpmUpdateResult(
        ok: false,
        detail:
            'Error: Transaction failed. Package conflicts with an '
            'installed package and cannot be resolved without removing it.',
      );
  @override
  Future<bool> repoEnabled() async => true;
  @override
  Future<String?> installedVersion() async => '1.0.0';
}

const _channel = MethodChannel('plugins.flutter.io/url_launcher');

List<String> _mockLauncher(WidgetTester tester, {bool result = true}) {
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    if (call.method == 'launch') {
      launched.add((call.arguments as Map)['url'] as String);
    }
    return result;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return launched;
}

Future<void> _pump(
  WidgetTester tester,
  InstallFormat format, {
  bool isWeb = false,
  VoidCallback? onReload,
  RpmUpdater? rpm,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ClientTooOldScreen(
          format: format,
          rpm: rpm,
          isWeb: isWeb,
          onReload: onReload,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final format in [InstallFormat.flatpak, InstallFormat.deb]) {
    testWidgets('$format: no github button, the hint is the action', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      await _pump(tester, format);
      expect(find.byType(AppButton), findsNothing);
      expect(launched, isEmpty);
    });
  }

  testWidgets('web: the button reloads the page', (tester) async {
    final launched = _mockLauncher(tester);
    var reloads = 0;
    await _pump(
      tester,
      InstallFormat.unknown,
      isWeb: true,
      onReload: () => reloads++,
    );
    await tester.tap(find.byType(AppButton));
    await tester.pump();
    expect(reloads, 1);
    expect(launched, isEmpty);
  });

  testWidgets('tarball: opens the release page', (tester) async {
    final launched = _mockLauncher(tester);
    await _pump(tester, InstallFormat.tarball);
    await tester.tap(find.byType(AppButton));
    await tester.pump();
    expect(launched, [releasesUrl]);
  });

  testWidgets('a launch that did not happen is shown', (tester) async {
    _mockLauncher(tester, result: false);
    await _pump(tester, InstallFormat.tarball);
    await tester.tap(find.byType(AppButton));
    await tester.pump();
    expect(find.byType(AppErrorState), findsOneWidget);
  });

  for (final (size, scale) in [
    (const Size(400, 300), 2.0),
    (const Size(800, 400), 1.0),
    (const Size(360, 640), 1.6),
  ]) {
    testWidgets('fits or scrolls at $size, text x$scale', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, InstallFormat.rpm, rpm: _FailingDnf(), size: size);
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Update now'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getRect(find.text('Update now')).bottom,
        lessThanOrEqualTo(size.height),
      );
    });
  }
}
