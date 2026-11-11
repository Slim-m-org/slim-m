// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A copy installed from Google Play is updated by Play, never by the apk
/// self-updater; a sideloaded copy keeps the updater. Every test host is a
/// desktop, so the Android answer is passed in explicitly.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/self_update/play_install.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/update_status_rows.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/async_wait.dart';

const _interval = Duration(hours: 1);

PackageInfo _info(String? installer) => PackageInfo(
  appName: 'slim-m',
  packageName: 'top.npcserver.slimm',
  version: '1.0.0',
  buildNumber: '1',
  installerStore: installer,
);

bool _onAndroid(PackageInfo info) => installedFromPlay(info, onAndroid: true);

const _update = ClientUpdate(
  version: '9.9.9',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

class _Check {
  var calls = 0;

  Future<ClientUpdate?> call({
    required String currentVersion,
    http.Client? client,
    InstallFormat? format,
  }) async {
    calls++;
    return _update;
  }
}

ProviderContainer _container(String? installer) => ProviderContainer(
  overrides: [
    appInfoProvider.overrideWith((ref) => Future.value(_info(installer))),
  ],
);

({UpdateWatcher watcher, _Check check}) _watch(
  ProviderContainer container,
  DateTime Function() now,
) {
  final check = _Check();
  final watcher = container.read(
    Provider(
      (ref) => UpdateWatcher(
        ref,
        interval: _interval,
        check: check.call,
        shouldRun: () => true,
        fromPlay: _onAndroid,
        startDelay: null,
        secondLaunches: const Stream.empty(),
        now: now,
      ),
    ),
  );
  return (watcher: watcher, check: check);
}

Widget _rows(String? installer) => ProviderScope(
  overrides: [
    appInfoProvider.overrideWith((ref) => Future.value(_info(installer))),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: UpdateStatusRows(
        check: ({client, required currentVersion, format}) async => _update,
        shouldRun: () => true,
        fromPlay: _onAndroid,
      ),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('installedFromPlay', () {
    test('is true only for the Play Store installer on Android', () {
      final play = _info(playStoreInstaller);
      expect(installedFromPlay(play, onAndroid: true), isTrue);
      expect(installedFromPlay(play, onAndroid: false), isFalse);
      expect(installedFromPlay(_info(null), onAndroid: true), isFalse);
      expect(
        installedFromPlay(
          _info('com.android.packageinstaller'),
          onAndroid: true,
        ),
        isFalse,
      );
    });
  });

  group('the update watcher', () {
    test('never checks, so offers nothing, on a Play install', () {
      fakeAsync((async) {
        final container = _container(playStoreInstaller);
        final (:watcher, :check) = _watch(
          container,
          async.getClock(DateTime(2026)).now,
        );
        addTearDown(watcher.dispose);
        addTearDown(container.dispose);

        watcher.start();
        async.elapse(_interval * 3);

        expect(check.calls, 0);
        expect(container.read(inSessionUpdateProvider), isNull);
      });
    });

    test('keeps checking on a sideloaded install', () {
      fakeAsync((async) {
        final container = _container(null);
        final (:watcher, :check) = _watch(
          container,
          async.getClock(DateTime(2026)).now,
        );
        addTearDown(watcher.dispose);
        addTearDown(container.dispose);

        watcher.start();
        async.elapse(_interval);

        expect(check.calls, 1);
        expect(container.read(inSessionUpdateProvider)?.version, '9.9.9');
      });
    });
  });

  group('Settings > About', () {
    testWidgets('a Play install says Play updates it and has no check button', (
      tester,
    ) async {
      await tester.pumpWidget(_rows(playStoreInstaller));
      await pumpFrames(tester);

      expect(find.text('Updates come from Google Play.'), findsOneWidget);
      expect(find.text('Check for updates'), findsNothing);
    });

    testWidgets('a sideload keeps its check button', (tester) async {
      await tester.pumpWidget(_rows(null));
      await pumpFrames(tester);

      expect(find.text('Check for updates'), findsOneWidget);
      expect(find.text('Updates come from Google Play.'), findsNothing);
    });
  });
}
