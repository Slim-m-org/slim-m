// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [updateAndroidApk]: the apk is fetched under the manifest's android key
/// into the cache folder the FileProvider shares, and only a verified file
/// ever reaches the installer.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/self_update/android_apk_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/update_manifest.dart';

class _Installer implements ApkInstaller {
  _Installer({this.error});

  final PlatformException? error;
  final installed = <String>[];

  @override
  Future<ApkInstallOutcome> install(File apk) async {
    if (error case final error?) throw error;
    installed.add(apk.path);
    return ApkInstallOutcome.started;
  }
}

void main() {
  final cache = Directory('/cache');
  final apk = File('/cache/updates/slim-m-client-android.apk');
  final client = http.Client();
  tearDownAll(client.close);

  Future<ApkInstallOutcome?> run(
    _Installer installer, {
    VerifiedUpdate? found,
    List<String>? asked,
    String architecture = 'arm64',
  }) => updateAndroidApk(
    architecture: architecture,
    currentVersion: '1.0.0',
    cacheDir: cache,
    client: client,
    installer: installer,
    fetch:
        ({
          required currentVersion,
          required platformKey,
          required stagingDir,
          required client,
          fallbackPlatformKey,
        }) async {
          asked?.addAll([
            currentVersion,
            platformKey,
            '$fallbackPlatformKey',
            stagingDir.path,
          ]);
          return found;
        },
  );

  test(
    'asks for the apk built for this CPU, falling back to the fat one',
    () async {
      final asked = <String>[];
      await run(_Installer(), asked: asked);
      expect(asked, [
        '1.0.0',
        'android-arm64-v8a',
        'android',
        '/cache/updates',
      ]);
    },
  );

  test('each CPU maps to its own apk key', () {
    expect(androidApkPlatformKey('arm64'), 'android-arm64-v8a');
    expect(androidApkPlatformKey('arm'), 'android-armeabi-v7a');
    expect(androidApkPlatformKey('x64'), 'android-x86_64');
    expect(androidApkPlatformKey('unknown'), isNull);
  });

  test('an unknown CPU asks only for the fat apk key', () async {
    final asked = <String>[];
    await run(_Installer(), asked: asked, architecture: 'unknown');
    expect(asked[1], 'android');
  });

  test('nothing newer installs nothing', () async {
    final installer = _Installer();
    expect(await run(installer), isNull);
    expect(installer.installed, isEmpty);
  });

  test('a verified download goes to the installer', () async {
    final installer = _Installer();
    final outcome = await run(
      installer,
      found: VerifiedUpdate.forTest(version: '2.0.0', tag: 't', file: apk),
    );
    expect(outcome, ApkInstallOutcome.started);
    expect(installer.installed, [apk.path]);
  });

  group('the staging folder', () {
    late Directory cache;
    late Directory staging;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('slimm-apk-update');
      staging = Directory('${cache.path}/$androidUpdateCacheDir')..createSync();
      addTearDown(() => cache.deleteSync(recursive: true));
    });

    File stage(String name) =>
        File('${staging.path}/$name')..writeAsStringSync('x');

    Future<ApkInstallOutcome?> runWith(
      Future<VerifiedUpdate?> Function() fetch,
    ) => updateAndroidApk(
      currentVersion: '1.0.0',
      cacheDir: cache,
      client: client,
      installer: _Installer(),
      fetch:
          ({
            required currentVersion,
            required platformKey,
            required stagingDir,
            required client,
            fallbackPlatformKey,
          }) => fetch(),
    );

    List<String> left() =>
        [for (final e in staging.listSync()) e.path.split('/').last]..sort();

    test('keeps only the apk being installed', () async {
      stage('slim-m-1.0.0.apk');
      stage('slim-m-1.5.0.apk.part');
      final fresh = stage('slim-m-2.0.0.apk');

      await runWith(
        () async =>
            VerifiedUpdate.forTest(version: '2.0.0', tag: 't', file: fresh),
      );

      expect(left(), ['slim-m-2.0.0.apk']);
    });

    test('nothing newer leaves nothing staged', () async {
      stage('slim-m-1.0.0.apk');

      expect(await runWith(() async => null), isNull);

      expect(left(), isEmpty);
    });

    test('a download that failed keeps its partial file to resume', () async {
      stage('slim-m-2.0.0.apk.part');

      await expectLater(
        runWith(
          () async => throw const SelfUpdateFailure(
            SelfUpdateFailureKind.downloadFailed,
            'interrupted',
          ),
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );

      expect(left(), ['slim-m-2.0.0.apk.part']);
    });
  });

  test('an installer that cannot open the apk is a failure, not a crash', () {
    expect(
      run(
        _Installer(error: PlatformException(code: 'error')),
        found: VerifiedUpdate.forTest(version: '2.0.0', tag: 't', file: apk),
      ),
      throwsA(
        isA<SelfUpdateFailure>().having(
          (f) => f.kind,
          'kind',
          SelfUpdateFailureKind.installFailed,
        ),
      ),
    );
  });
}
