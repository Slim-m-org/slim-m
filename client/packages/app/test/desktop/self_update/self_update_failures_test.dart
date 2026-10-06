// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every install failure ends in the banner as a SelfUpdateFailure, whatever
/// exception type the failing step threw.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/desktop/self_update/linux_install.dart';
import 'package:slimm_app/src/desktop/self_update/linux_layout.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/update_download.dart';
import 'package:slimm_app/src/desktop/self_update/update_manifest.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  late Directory root;
  late String exe;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-f0017-');
    final v = Directory('${root.path}/0.88.0')..createSync();
    File('${v.path}/slimm_app').writeAsStringSync('x');
    Link('${root.path}/current').createSync('0.88.0');
    exe = '${v.path}/slimm_app';
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'a captive-portal 200 ends in a banner failure, not a thrown FormatException',
    () async {
      final c = ProviderContainer(
        overrides: [
          selfUpdateProvider.overrideWith(
            (ref) => SelfUpdateController(
              ref,
              newClient: () => MockClient(
                (_) async => http.Response('<html>please log in</html>', 200),
              ),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      final result = await c
          .read(selfUpdateProvider)
          .install(
            currentVersion: '0.88.0',
            format: InstallFormat.tarball,
            resolvedExecutable: exe,
            os: 'linux',
          );

      expect(result, isNull);
      expect(
        c.read(selfUpdateFailureProvider),
        isNotNull,
        reason: 'the failure must land in selfUpdateFailureProvider',
      );
    },
  );

  test(
    'an unusable staging dir ends in a SelfUpdateFailure, not a FileSystemException',
    () async {
      final blocker = File('${root.path}/blocker')..writeAsStringSync('file');
      final artifact = UpdateArtifact(
        url: Uri.parse('https://example.invalid/slim-m.tar.gz'),
        sha256: '00',
        size: 1,
      );
      await expectLater(
        downloadArtifact(
          artifact: artifact,
          stagingDir: Directory('${blocker.path}/staging'),
          client: MockClient((_) async => http.Response('x', 200)),
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );
    },
  );

  test(
    'a missing tar ends in an installFailed failure, not a ProcessException',
    () async {
      final file = File('${root.path}/.staging/pkg.tar.gz')
        ..createSync(recursive: true);
      await expectLater(
        installLinuxUpdate(
          update: VerifiedUpdate.forTest(
            version: '0.89.0',
            tag: 'client-v0.89.0',
            file: file,
          ),
          format: InstallFormat.tarball,
          layout: LinuxInstallLayout(root),
          unpack: (archive, into) async =>
              throw const ProcessException('tar', ['-xzf'], 'not found', 2),
        ),
        throwsA(
          isA<SelfUpdateFailure>().having(
            (f) => f.kind,
            'kind',
            SelfUpdateFailureKind.installFailed,
          ),
        ),
      );
    },
  );

  test('any other error from a step still lands in the banner', () async {
    final c = ProviderContainer(
      overrides: [
        selfUpdateProvider.overrideWith(
          (ref) => SelfUpdateController(
            ref,
            fetch:
                ({
                  required currentVersion,
                  required platformKey,
                  required stagingDir,
                  required client,
                  freeSpace,
                }) async => throw StateError('boom'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);

    final result = await c
        .read(selfUpdateProvider)
        .install(
          currentVersion: '0.88.0',
          format: InstallFormat.tarball,
          resolvedExecutable: exe,
          os: 'linux',
        );

    expect(result, isNull);
    expect(c.read(selfUpdateFailureProvider)?.detail, contains('boom'));
    expect(c.read(selfUpdateInstallingProvider), isFalse);
  });
}
