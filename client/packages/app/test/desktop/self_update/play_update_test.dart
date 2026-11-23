// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Play's flexible in-app update for a Play install, driven through a fake of
/// the in_app_update plugin. Every test host is a desktop, so the Android
/// answer is passed in explicitly and the watcher really takes its Play branch.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/self_update/play_install.dart';
import 'package:slimm_app/src/desktop/self_update/play_update.dart';
import 'package:slimm_app/src/desktop/update_available_banner.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/update_status_rows.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/async_wait.dart';

AppUpdateInfo _report({
  UpdateAvailability availability = UpdateAvailability.updateAvailable,
  bool flexible = true,
  InstallStatus status = InstallStatus.unknown,
}) => AppUpdateInfo(
  updateAvailability: availability,
  immediateUpdateAllowed: true,
  immediateAllowedPreconditions: const [],
  flexibleUpdateAllowed: flexible,
  flexibleAllowedPreconditions: const [],
  availableVersionCode: 42,
  installStatus: status,
  packageName: 'top.npcserver.slimm',
  clientVersionStalenessDays: 0,
  updatePriority: 0,
);

class _FakePlay implements PlayUpdatePort {
  AppUpdateInfo report = _report();
  Object? checkError;
  var checks = 0;
  var starts = 0;
  var completes = 0;
  Completer<AppUpdateResult> download = Completer();
  final statuses = StreamController<InstallStatus>.broadcast();

  @override
  Future<AppUpdateInfo> checkForUpdate() async {
    checks++;
    if (checkError case final error?) throw error;
    return report;
  }

  @override
  Future<AppUpdateResult> startFlexibleUpdate() {
    starts++;
    return download.future;
  }

  @override
  Future<void> completeFlexibleUpdate() {
    completes++;
    return Completer<void>().future;
  }

  @override
  Stream<InstallStatus> get installStatus => statuses.stream;
}

PackageInfo _info(String? installer) => PackageInfo(
  appName: 'slim-m',
  packageName: 'top.npcserver.slimm',
  version: '1.0.0',
  buildNumber: '1',
  installerStore: installer,
);

ProviderContainer _container(_FakePlay play, {String? installer}) {
  final container = ProviderContainer(
    overrides: [
      playUpdatePortProvider.overrideWithValue(play),
      appInfoProvider.overrideWith((ref) async => _info(installer)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('installedFromPlay', () {
    test('the Play build counts as Play whoever installed it', () {
      expect(
        installedFromPlay(_info(null), onAndroid: true, isPlayBuild: true),
        isTrue,
      );
      expect(
        installedFromPlay(_info(null), onAndroid: false, isPlayBuild: true),
        isFalse,
      );
      expect(installedFromPlay(_info(null), onAndroid: true), isFalse);
    });
  });

  group('playStageFor', () {
    test('offers a flexible update Play has', () {
      expect(playStageFor(_report()), PlayUpdateStage.available);
    });

    test('offers nothing when there is none or flexible is not allowed', () {
      expect(
        playStageFor(
          _report(availability: UpdateAvailability.updateNotAvailable),
        ),
        PlayUpdateStage.none,
      );
      expect(playStageFor(_report(flexible: false)), PlayUpdateStage.none);
    });

    test('picks up a download Play kept going across a restart', () {
      const busy = UpdateAvailability.developerTriggeredUpdateInProgress;
      expect(
        playStageFor(
          _report(availability: busy, status: InstallStatus.downloading),
        ),
        PlayUpdateStage.downloading,
      );
      expect(
        playStageFor(
          _report(availability: busy, status: InstallStatus.downloaded),
        ),
        PlayUpdateStage.downloaded,
      );
    });
  });

  group('playStageAfter', () {
    test('a cancel or a failure offers the update again', () {
      for (final status in [InstallStatus.canceled, InstallStatus.failed]) {
        expect(
          playStageAfter(status, PlayUpdateStage.downloading),
          PlayUpdateStage.available,
        );
      }
    });

    test('an unknown status keeps the stage', () {
      expect(
        playStageAfter(InstallStatus.unknown, PlayUpdateStage.downloading),
        PlayUpdateStage.downloading,
      );
    });
  });

  group('the controller', () {
    test('downloads on start and restarts only once downloaded', () async {
      final play = _FakePlay();
      final container = _container(play);
      final controller = container.read(playUpdateProvider.notifier);

      controller.restart();
      await controller.refresh();
      expect(container.read(playUpdateProvider), PlayUpdateStage.available);

      final started = controller.start();
      expect(container.read(playUpdateProvider), PlayUpdateStage.downloading);
      controller.restart();
      expect(play.completes, 0);

      play.download.complete(AppUpdateResult.success);
      await started;
      expect(container.read(playUpdateProvider), PlayUpdateStage.downloaded);

      controller.restart();
      expect(play.completes, 1);
    });

    test('a decline or a plugin error offers it again', () async {
      final play = _FakePlay();
      final container = _container(play);
      final controller = container.read(playUpdateProvider.notifier);
      await controller.refresh();

      final declined = controller.start();
      play.download.complete(AppUpdateResult.userDeniedUpdate);
      await declined;
      expect(container.read(playUpdateProvider), PlayUpdateStage.available);

      play.download = Completer()..completeError(PlatformException(code: 'x'));
      await controller.start();
      expect(container.read(playUpdateProvider), PlayUpdateStage.available);
      expect(play.starts, 2);
    });

    test(
      'a download cancelled from the notification offers it again',
      () async {
        final play = _FakePlay();
        final container = _container(play);
        final controller = container.read(playUpdateProvider.notifier);
        await controller.refresh();

        unawaited(controller.start());
        play.statuses.add(InstallStatus.canceled);
        await pumpEventQueue();

        expect(container.read(playUpdateProvider), PlayUpdateStage.available);
      },
    );

    test('a download kept across a restart finishes into Restart', () async {
      final play = _FakePlay()
        ..report = _report(status: InstallStatus.downloading);
      final container = _container(play);
      container.listen(playUpdateProvider, (_, _) {});
      await container.read(playUpdateProvider.notifier).refresh();
      expect(container.read(playUpdateProvider), PlayUpdateStage.downloading);

      play.statuses.add(InstallStatus.downloaded);
      await pumpEventQueue();

      expect(container.read(playUpdateProvider), PlayUpdateStage.downloaded);
    });

    test('a failed check keeps what it had', () async {
      final play = _FakePlay();
      final container = _container(play);
      final controller = container.read(playUpdateProvider.notifier);
      await controller.refresh();

      play.checkError = PlatformException(code: 'TASK_FAILURE');
      await controller.refresh();

      expect(container.read(playUpdateProvider), PlayUpdateStage.available);
    });
  });

  group('the watcher on a Play install', () {
    test('asks Play, never GitHub, and shows the banner and badge', () {
      fakeAsync((async) {
        final play = _FakePlay();
        final container = _container(play, installer: playStoreInstaller);
        var githubChecks = 0;
        final watcher = container.read(
          Provider(
            (ref) => UpdateWatcher(
              ref,
              interval: const Duration(hours: 1),
              check:
                  ({
                    required String currentVersion,
                    http.Client? client,
                    InstallFormat? format,
                  }) async {
                    githubChecks++;
                    return null;
                  },
              shouldRun: () => true,
              fromPlay: (info) => installedFromPlay(info, onAndroid: true),
              startDelay: null,
              secondLaunches: const Stream.empty(),
              now: async.getClock(DateTime(2026)).now,
            ),
          ),
        );
        addTearDown(watcher.dispose);

        watcher.start();
        async.elapse(const Duration(hours: 1));

        expect(play.checks, 1);
        expect(githubChecks, 0);
        expect(container.read(bannerVisibleProvider), isTrue);
        expect(container.read(updatePendingProvider), isTrue);
      });
    });
  });

  group('the banner', () {
    Future<(_FakePlay, ProviderContainer)> pump(WidgetTester tester) async {
      final play = _FakePlay();
      final container = ProviderContainer(
        overrides: [
          playUpdatePortProvider.overrideWithValue(play),
          updateWatcherProvider.overrideWith(
            (ref) => UpdateWatcher(ref, shouldRun: () => false),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(
              body: UpdateAvailableBanner(restartApplies: false),
            ),
          ),
        ),
      );
      await container.read(playUpdateProvider.notifier).refresh();
      await tester.pump();
      return (play, container);
    }

    testWidgets('offers, downloads, then restarts through Play', (
      tester,
    ) async {
      final (play, _) = await pump(tester);
      expect(find.text('An update is available.'), findsOneWidget);
      expect(find.text('Version 9.9.9 is available.'), findsNothing);

      await tester.tap(find.text('Update'));
      await tester.pump();
      expect(find.text('Downloading...'), findsOneWidget);
      expect(play.starts, 1);

      play.download.complete(AppUpdateResult.success);
      await pumpFrames(tester);
      expect(find.text('The update is ready.'), findsOneWidget);

      await tester.tap(find.text('Restart'));
      expect(play.completes, 1);
    });

    testWidgets('a dismissed offer comes back once the download is ready', (
      tester,
    ) async {
      final (play, container) = await pump(tester);
      await tester.tap(find.bySemanticsLabel('Dismiss'));
      await tester.pump();
      expect(find.text('An update is available.'), findsNothing);

      play.report = _report(status: InstallStatus.downloaded);
      await container.read(playUpdateProvider.notifier).refresh();
      await tester.pump();

      expect(find.text('The update is ready.'), findsOneWidget);
    });
  });

  testWidgets('Settings > About offers the Play update', (tester) async {
    final play = _FakePlay();
    final container = ProviderContainer(
      overrides: [
        playUpdatePortProvider.overrideWithValue(play),
        appInfoProvider.overrideWith((ref) async => _info(playStoreInstaller)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: UpdateStatusRows(
              shouldRun: () => true,
              fromPlay: (info) => installedFromPlay(info, onAndroid: true),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('Update'), findsNothing);

    await container.read(playUpdateProvider.notifier).refresh();
    await tester.pump();

    expect(find.text('Updates come from Google Play.'), findsOneWidget);
    expect(find.text('Check for updates'), findsNothing);
    await tester.tap(find.text('Update'));
    expect(play.starts, 1);
  });
}
