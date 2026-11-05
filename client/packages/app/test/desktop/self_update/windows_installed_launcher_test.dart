// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// After "Move and update", an old shortcut still opens the extracted copy;
/// that copy hands over to the per-user install instead of offering the same
/// update again.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/relaunch.dart';
import 'package:slimm_app/src/desktop/self_update/windows_adopt.dart';
import 'package:slimm_app/src/desktop/startup_updates.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory bundle;
  late Directory root;

  void installed(String version) {
    Directory('${root.path}/app-$version').createSync(recursive: true);
    File('${root.path}/app-$version/slimm_app.exe').writeAsStringSync('app');
    File('${root.path}/slim-m.exe').writeAsStringSync('launcher');
    File('${root.path}/current').writeAsStringSync(version);
  }

  File? launcherFor(String version) => installedLauncherFor(
    executable: '${bundle.path}/slimm_app.exe',
    version: version,
    root: root,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('slimm-installed-launcher-');
    bundle = Directory('${temp.path}/Downloads/slim-m-0.122.0')
      ..createSync(recursive: true);
    File('${bundle.path}/slimm_app.exe').writeAsStringSync('app');
    File('${bundle.path}/slim-m.exe').writeAsStringSync('launcher');
    root = Directory('${temp.path}/local/slim-m');
  });
  tearDown(() {
    relaunchLauncherOverride = null;
    temp.deleteSync(recursive: true);
  });

  test('an old copy finds the newer install a Move and update left', () {
    installed('0.123.0');
    expect(launcherFor('0.122.0')?.path, '${root.path}/slim-m.exe');
  });

  test('the same version installed is handed over to as well', () {
    installed('0.122.0');
    expect(launcherFor('0.122.0'), isNotNull);
  });

  test('a copy newer than the install keeps running itself', () {
    installed('0.121.0');
    expect(launcherFor('0.122.0'), isNull);
  });

  test('with no install, or a half-written one, it runs itself', () {
    expect(launcherFor('0.122.0'), isNull);
    installed('0.123.0');
    File('${root.path}/app-0.123.0/slimm_app.exe').deleteSync();
    expect(launcherFor('0.122.0'), isNull);
  });

  test('the startup pass hands over before it checks for updates', () async {
    installed('0.123.0');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var checked = false;
    var relaunched = 0;
    await runStartupUpdates(
      container,
      StartupUpdateDeps(
        check:
            ({
              required String currentVersion,
              http.Client? client,
              InstallFormat? format,
            }) async {
              checked = true;
              return null;
            },
        relaunch: () async => relaunched++,
        currentVersion: '0.122.0',
        installedLauncher: (version) => launcherFor(version),
      ),
    );
    expect(relaunched, 1);
    expect(relaunchLauncherOverride, '${root.path}/slim-m.exe');
    expect(checked, isFalse);
  });

  test('it hands over even with automatic updates off', () async {
    SharedPreferences.setMockInitialValues({'slimm.updates.automatic': false});
    installed('0.123.0');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var relaunched = 0;
    await runStartupUpdates(
      container,
      StartupUpdateDeps(
        relaunch: () async => relaunched++,
        currentVersion: '0.122.0',
        installedLauncher: (version) => launcherFor(version),
      ),
    );
    expect(relaunched, 1);
  });

  test('a copy with nothing to hand over to checks as before', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var checked = false;
    await runStartupUpdates(
      container,
      StartupUpdateDeps(
        check:
            ({
              required String currentVersion,
              http.Client? client,
              InstallFormat? format,
            }) async {
              checked = true;
              return null;
            },
        relaunch: () async {},
        currentVersion: '0.122.0',
        installedLauncher: (version) => launcherFor(version),
      ),
    );
    expect(checked, isTrue);
  });
}
