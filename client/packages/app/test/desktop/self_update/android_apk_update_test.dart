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
  }) => updateAndroidApk(
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
        }) async {
          asked?.addAll([currentVersion, platformKey, stagingDir.path]);
          return found;
        },
  );

  test('asks for the android artifact into the shared cache folder', () async {
    final asked = <String>[];
    await run(_Installer(), asked: asked);
    expect(asked, ['1.0.0', 'android', '/cache/updates']);
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
