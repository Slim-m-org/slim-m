// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [UpdateAvailableBanner] itself: it renders nothing until a session check
/// finds something, names the version, and dismissing it both hides it and
/// writes the same dismissal the splash's own "Not now" uses.
///
/// [inSessionUpdateProvider] is overridden directly rather than driven
/// through a real [UpdateWatcher]: this file is only about what the banner
/// does with a find, not how one arrives - `update_watch_test.dart` covers
/// the timer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/self_update/android_apk_update.dart';
import 'package:slimm_app/src/desktop/update_available_banner.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _update = ClientUpdate(
  version: '9.9.9',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

Future<void> _pump(
  WidgetTester tester,
  ClientUpdate? update, {
  bool restartApplies = true,
  Future<ApkInstallOutcome?> Function(String)? runApkUpdate,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inSessionUpdateProvider.overrideWith((ref) => update),
        // No real Timer here: this file is about the banner, not the poll.
        updateWatcherProvider.overrideWith(
          (ref) => UpdateWatcher(ref, shouldRun: () => false),
        ),
        appInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'slim-m',
            packageName: 'top.npcserver.slimm',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
        if (runApkUpdate != null)
          apkUpdateRunnerProvider.overrideWithValue(runApkUpdate),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: UpdateAvailableBanner(restartApplies: restartApplies),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders nothing while no update has been found', (tester) async {
    await _pump(tester, null);

    expect(find.byType(AppCallout), findsNothing);
  });

  testWidgets('names the version once one is found', (tester) async {
    await _pump(tester, _update);

    expect(find.byType(AppCallout), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsOneWidget);
    expect(find.textContaining('Restart'), findsOneWidget);
  });

  testWidgets(
    'dismissing hides the banner and records the same dismissal the splash '
    'reads',
    (tester) async {
      await _pump(tester, _update);
      expect(find.byType(AppCallout), findsOneWidget);

      await tester.tap(find.byType(AppIconButton));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AppCallout), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(dismissedUpdateVersionKey), '9.9.9');
    },
  );
  testWidgets('a sideloaded build is offered an update, not a restart', (
    tester,
  ) async {
    // No splash to pass back through, and no store to hand off to either.
    await _pump(tester, _update, restartApplies: false);

    expect(find.textContaining('9.9.9'), findsOneWidget);
    expect(
      find.textContaining('Restart'),
      findsNothing,
      reason: 'restarting a sideloaded apk does not update it',
    );
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('Update installs over the running version, once at a time', (
    tester,
  ) async {
    final started = <String>[];
    final finish = Completer<ApkInstallOutcome?>();
    await _pump(
      tester,
      _update,
      restartApplies: false,
      runApkUpdate: (version) {
        started.add(version);
        return finish.future;
      },
    );

    await tester.tap(find.text('Update'));
    await tester.pump();
    await tester.pump();
    expect(started, ['1.0.0']);
    expect(find.text('Downloading...'), findsOneWidget);
    await tester.tap(find.text('Downloading...'));
    await tester.pump();
    expect(started, hasLength(1), reason: 'a second download never starts');

    finish.complete(ApkInstallOutcome.started);
    await tester.pump();
    await tester.pump();
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('a build that restarts into its update is told to restart', (
    tester,
  ) async {
    await _pump(tester, _update, restartApplies: true);

    expect(find.textContaining('Restart slim-m'), findsOneWidget);
    expect(
      find.text('Update'),
      findsNothing,
      reason: 'the splash re-derives the real mechanism on restart',
    );
  });
}
