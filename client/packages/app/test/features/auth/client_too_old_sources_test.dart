// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The too-old screen offers each install source its own update step, and a
/// way off the blocked Space that needs no update (audit lane aud19-l2).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/desktop/self_update/android_apk_update.dart';
import 'package:slimm_app/src/desktop/self_update/play_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/auth/widgets/client_too_old_actions.dart';
import 'package:slimm_app/src/features/auth/widgets/client_too_old_gate.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../accounts/account_host_harness.dart';

const _channel = MethodChannel('plugins.flutter.io/url_launcher');

List<String> _mockLauncher(
  WidgetTester tester, {
  Set<String> refuse = const {},
}) {
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    if (call.method != 'launch') return true;
    final url = (call.arguments as Map)['url'] as String;
    launched.add(url);
    return !refuse.any(url.startsWith);
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return launched;
}

AppUpdateInfo _playReport(UpdateAvailability availability) => AppUpdateInfo(
  updateAvailability: availability,
  immediateUpdateAllowed: true,
  immediateAllowedPreconditions: const [],
  flexibleUpdateAllowed: true,
  flexibleAllowedPreconditions: const [],
  availableVersionCode: 42,
  installStatus: InstallStatus.unknown,
  packageName: 'top.npcserver.slimm',
  clientVersionStalenessDays: 0,
  updatePriority: 0,
);

class _FakePlay implements PlayUpdatePort {
  _FakePlay(this.availability);

  final UpdateAvailability availability;
  var starts = 0;

  @override
  Future<AppUpdateInfo> checkForUpdate() async => _playReport(availability);

  @override
  Future<AppUpdateResult> startFlexibleUpdate() async {
    starts++;
    return AppUpdateResult.success;
  }

  @override
  Future<void> completeFlexibleUpdate() async {}

  @override
  Stream<InstallStatus> get installStatus => const Stream.empty();
}

class _FakeSelfUpdate implements SelfUpdateController {
  _FakeSelfUpdate(this.result);

  final String? result;
  var installs = 0;

  @override
  Future<String?> install({
    required String currentVersion,
    InstallFormat? format,
    String? resolvedExecutable,
    String? os,
  }) async {
    installs++;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _pump(
  WidgetTester tester, {
  InstallFormat format = InstallFormat.unknown,
  bool? fromPlay,
  bool? fromAppStore,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'slim-m',
            packageName: 'top.npcserver.slimm',
            version: '0.1.0',
            buildNumber: '1',
          ),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ClientTooOldScreen(
          format: format,
          fromPlay: fromPlay,
          fromAppStore: fromAppStore,
          relaunch: () async {},
          canRelaunch: true,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('install sources', () {
    testWidgets('play: runs the play update, not the release page', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      final play = _FakePlay(UpdateAvailability.updateAvailable);
      await _pump(
        tester,
        format: InstallFormat.apk,
        fromPlay: true,
        overrides: [playUpdatePortProvider.overrideWithValue(play)],
      );
      expect(find.text('Update slim-m in Google Play.'), findsOneWidget);
      await tester.tap(find.text('Update in Google Play'));
      await tester.pump();
      await tester.pump();
      expect(play.starts, 1);
      expect(launched, isEmpty);
      expect(find.text('Restart'), findsOneWidget);
    });

    testWidgets('play with nothing offered: opens the store listing', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      await _pump(
        tester,
        format: InstallFormat.apk,
        fromPlay: true,
        overrides: [
          playUpdatePortProvider.overrideWithValue(
            _FakePlay(UpdateAvailability.updateNotAvailable),
          ),
        ],
      );
      await tester.tap(find.text('Update in Google Play'));
      await tester.pump();
      await tester.pump();
      expect(launched, [playListingUrl]);
    });

    testWidgets('play listing falls back to the web page', (tester) async {
      final launched = _mockLauncher(tester, refuse: {'market://'});
      await _pump(
        tester,
        format: InstallFormat.apk,
        fromPlay: true,
        overrides: [
          playUpdatePortProvider.overrideWithValue(
            _FakePlay(UpdateAvailability.updateNotAvailable),
          ),
        ],
      );
      await tester.tap(find.text('Update in Google Play'));
      await tester.pump();
      await tester.pump();
      expect(launched, [playListingUrl, playListingWebUrl]);
    });

    testWidgets('sideload: updates in the app through the apk runner', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      final versions = <String>[];
      await _pump(
        tester,
        format: InstallFormat.apk,
        fromPlay: false,
        overrides: [
          apkUpdateRunnerProvider.overrideWithValue((version) async {
            versions.add(version);
            return ApkInstallOutcome.started;
          }),
        ],
      );
      await tester.tap(find.text('Update now'));
      await tester.pump();
      await tester.pump();
      expect(versions, ['0.1.0']);
      expect(launched, isEmpty);
    });

    testWidgets('sideload with no apk in the release: opens the release page', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      await _pump(
        tester,
        format: InstallFormat.apk,
        fromPlay: false,
        overrides: [
          apkUpdateRunnerProvider.overrideWithValue((_) async => null),
        ],
      );
      await tester.tap(find.text('Update now'));
      await tester.pump();
      await tester.pump();
      expect(launched, [releasesUrl]);
    });

    testWidgets('desktop self-updater: installs in place, then restarts', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      final self = _FakeSelfUpdate('9.9.9');
      await _pump(
        tester,
        format: InstallFormat.tarball,
        overrides: [
          selfApplyAvailableProvider.overrideWithValue(true),
          selfUpdateProvider.overrideWithValue(self),
        ],
      );
      await tester.tap(find.text('Update now'));
      await tester.pump();
      await tester.pump();
      expect(self.installs, 1);
      expect(find.text('Restart'), findsOneWidget);
      expect(launched, isEmpty);
    });

    testWidgets('a tarball that cannot replace itself keeps the release page', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      await _pump(tester, format: InstallFormat.tarball);
      await tester.tap(find.text('Open the release'));
      await tester.pump();
      expect(launched, [releasesUrl]);
    });

    testWidgets('app store iphone: opens the store, not testflight', (
      tester,
    ) async {
      final launched = _mockLauncher(tester);
      await _pump(tester, format: InstallFormat.testFlight, fromAppStore: true);
      expect(find.text('Update slim-m in the App Store.'), findsOneWidget);
      await tester.tap(find.text('Open the App Store'));
      await tester.pump();
      expect(launched, [appStoreUrl]);
    });
  });

  group('account escape', () {
    late AccountHarness h;
    tearDown(() async => h.dispose());

    Future<void> pumpWithHost(WidgetTester tester) => _pump(
      tester,
      overrides: [accountHostProvider.overrideWith((ref) => h.host)],
    );

    testWidgets('use another space switches to the next account', (
      tester,
    ) async {
      h = AccountHarness();
      await h.seed('https://first.example', user: 'ann', active: true);
      await h.seed('https://second.example', user: 'bea');
      await tester.runAsync(h.boot);
      await pumpWithHost(tester);

      await tester.tap(find.text('Use another Space'));
      await tester.runAsync(() => pumpEventQueueTimes());

      expect(h.host.active!.account!.origin, 'https://second.example');
    });

    testWidgets('use another space with one account opens the add flow', (
      tester,
    ) async {
      h = AccountHarness();
      await h.seed('https://first.example', user: 'ann', active: true);
      await tester.runAsync(h.boot);
      await pumpWithHost(tester);

      await tester.tap(find.text('Use another Space'));
      await tester.runAsync(() => pumpEventQueueTimes());

      expect(h.host.adding, isTrue);
    });

    testWidgets('sign out ends the blocked session', (tester) async {
      h = AccountHarness();
      await h.seed('https://first.example', user: 'ann', active: true);
      await tester.runAsync(h.boot);
      final blocked = h.host.active!;
      await pumpWithHost(tester);

      await tester.tap(find.text('Sign out of this Space'));
      await tester.runAsync(() => pumpEventQueueTimes());

      expect(blocked.container.read(sessionProvider).isSignedIn, isFalse);
    });

    testWidgets('no host, no escape buttons', (tester) async {
      h = AccountHarness();
      await _pump(tester);
      expect(find.text('Use another Space'), findsNothing);
      expect(find.text('Sign out of this Space'), findsNothing);
    });
  });
}
