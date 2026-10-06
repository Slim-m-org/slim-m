// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop chrome keeps the periodic update check running.
///
/// The watcher is an autoDispose provider that lives only while something
/// watches it. Its one watcher was the update banner, and a frameless shell
/// (every Linux window once it is ready) mounts no banner, so the six hourly
/// check never started and the title bar chip, the window menu item and the
/// gear badge waited for a manual check.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/desktop_chrome.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/fake_desktop_window_port.dart';

/// Pumps the chrome, advances a whole watch interval, and answers how many
/// times the check ran and what it found.
Future<({int checks, String? found})> _runAnInterval(
  WidgetTester tester, {
  required bool shellActive,
  required bool frameless,
}) async {
  SharedPreferences.setMockInitialValues({});
  DesktopWindowShell.debugPort = FakeDesktopWindowPort();
  if (shellActive) DesktopWindowShell.debugActivate(frameless: frameless);
  addTearDown(DesktopWindowShell.debugReset);
  tester.view.physicalSize = const Size(1400, 880);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  var checks = 0;
  Future<ClientUpdate?> fakeCheck({
    required String currentVersion,
    http.Client? client,
    InstallFormat? format,
  }) async {
    checks++;
    return const ClientUpdate(
      version: '9.9.9',
      releaseUrl: 'https://example.invalid/r',
      format: InstallFormat.tarball,
    );
  }

  final container = ProviderContainer(
    overrides: [
      appInfoProvider.overrideWith(
        (ref) => Future.value(
          PackageInfo(
            appName: 'slim-m',
            packageName: 't',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
      ),
      // The real provider body, with only the network check and shouldRun swapped.
      updateWatcherProvider.overrideWith((ref) {
        final watcher = UpdateWatcher(
          ref,
          check: fakeCheck,
          shouldRun: () => true,
        );
        watcher.start();
        ref.onDispose(watcher.dispose);
        return watcher;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        builder: (context, child) => DesktopChrome(child: child!),
        home: const SizedBox.expand(),
      ),
    ),
  );
  await tester.pump(updateWatchInterval + const Duration(minutes: 1));
  await tester.pump();
  await tester.pump();

  final result = (
    checks: checks,
    found: container.read(inSessionUpdateProvider)?.version,
  );
  // Disposed before the test body ends, so the periodic timer is not left pending.
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  return result;
}

void main() {
  testWidgets('a frameless chrome runs the periodic check', (tester) async {
    final run = await _runAnInterval(
      tester,
      shellActive: true,
      frameless: true,
    );

    expect(run.checks, 1);
    expect(run.found, '9.9.9');
  });

  testWidgets('a framed chrome still runs it', (tester) async {
    final run = await _runAnInterval(
      tester,
      shellActive: true,
      frameless: false,
    );

    expect(run.checks, 1);
    expect(run.found, '9.9.9');
  });

  testWidgets('with no desktop shell the chrome starts nothing', (
    tester,
  ) async {
    final run = await _runAnInterval(
      tester,
      shellActive: false,
      frameless: false,
    );

    expect(run.checks, 0);
  });
}
