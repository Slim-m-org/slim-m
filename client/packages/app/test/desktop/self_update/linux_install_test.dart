// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/self_update/linux_install.dart';
import 'package:slimm_app/src/desktop/self_update/linux_layout.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_platform/platform.dart';

const _launcherPath = '../../../packaging/linux/slim-m';

void _makeVersion(Directory root, String version, {String app = 'exit 0'}) {
  final dir = Directory('${root.path}/$version')..createSync(recursive: true);
  File('${dir.path}/slimm_app').writeAsStringSync('#!/bin/sh\n$app\n');
  File('${dir.path}/slim-m').writeAsStringSync(
    File(_launcherPath).existsSync()
        ? File(_launcherPath).readAsStringSync()
        : '#!/bin/sh\nexec "\$(dirname "\$0")/slimm_app"\n',
  );
  for (final name in ['slimm_app', 'slim-m']) {
    Process.runSync('chmod', ['+x', '${dir.path}/$name']);
  }
}

void _point(Directory root, String link, String version) =>
    Link('${root.path}/$link').createSync(version);

Future<void> _fakeUnpack(File archive, Directory into) async {
  File('${into.path}/slimm_app').writeAsStringSync('#!/bin/sh\nexit 0\n');
  File('${into.path}/slim-m').writeAsStringSync('#!/bin/sh\nexit 0\n');
}

VerifiedUpdate _update(Directory root, String version) {
  final file = File('${root.path}/.staging/pkg-$version.tar.gz')
    ..createSync(recursive: true);
  return VerifiedUpdate.forTest(
    version: version,
    tag: 'client-v$version',
    file: file,
  );
}

String? _target(Directory root, String link) {
  final entity = Link('${root.path}/$link');
  return entity.existsSync() ? entity.targetSync() : null;
}

List<String> _names(Directory root) =>
    root
        .listSync(followLinks: false)
        .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList()
      ..sort();

void main() {
  late Directory root;
  late LinuxInstallLayout layout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-linux-install-');
    _makeVersion(root, '0.88.0');
    _point(root, 'current', '0.88.0');
    layout = LinuxInstallLayout(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('installLinuxUpdate', () {
    test(
      'publishes the version and swaps current, keeping the old one',
      () async {
        await installLinuxUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: layout,
          unpack: _fakeUnpack,
        );
        expect(_target(root, 'current'), '0.89.0');
        expect(_target(root, 'previous'), '0.88.0');
        expect(File('${root.path}/pending').readAsStringSync(), '0.89.0');
        expect(Directory('${root.path}/0.88.0').existsSync(), isTrue);
        expect(_names(root).where((n) => n.startsWith('.unpack')), isEmpty);
        expect(_names(root).where((n) => n.endsWith('.new')), isEmpty);
      },
    );

    test(
      'an interrupted unpack leaves current and the tree untouched',
      () async {
        final before = _names(root);
        await expectLater(
          installLinuxUpdate(
            update: _update(root, '0.89.0'),
            format: InstallFormat.tarball,
            layout: layout,
            unpack: (archive, into) async {
              File('${into.path}/slimm_app').writeAsStringSync('half');
              throw const FileSystemException('disk full');
            },
          ),
          throwsA(
            isA<SelfUpdateFailure>().having(
              (f) => f.kind,
              'kind',
              SelfUpdateFailureKind.installFailed,
            ),
          ),
        );
        expect(_target(root, 'current'), '0.88.0');
        expect(Directory('${root.path}/0.89.0').existsSync(), isFalse);
        expect(_target(root, 'previous'), isNull);
        expect(File('${root.path}/pending').existsSync(), isFalse);
        expect(_names(root).where((n) => n != '.staging'), before);
      },
    );

    test('a tarball without the app is not published', () async {
      await expectLater(
        installLinuxUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: layout,
          unpack: (archive, into) async {},
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );
      expect(_target(root, 'current'), '0.88.0');
      expect(Directory('${root.path}/0.89.0').existsSync(), isFalse);
    });

    test(
      'a leftover temp link from a killed swap does not block the next',
      () async {
        Link('${root.path}/.current.new').createSync('0.0.1');
        await installLinuxUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: layout,
          unpack: _fakeUnpack,
        );
        expect(_target(root, 'current'), '0.89.0');
      },
    );

    for (final format in [
      InstallFormat.rpm,
      InstallFormat.deb,
      InstallFormat.flatpak,
      InstallFormat.unknown,
    ]) {
      test('${format.name} refuses and changes nothing', () async {
        await expectLater(
          installLinuxUpdate(
            update: _update(root, '0.89.0'),
            format: format,
            layout: layout,
            unpack: _fakeUnpack,
          ),
          throwsA(
            isA<SelfUpdateFailure>().having(
              (f) => f.kind,
              'kind',
              SelfUpdateFailureKind.unsupportedInstall,
            ),
          ),
        );
        expect(_target(root, 'current'), '0.88.0');
        expect(Directory('${root.path}/0.89.0').existsSync(), isFalse);
      });
    }

    test('a tarball outside the per-user layout refuses', () async {
      await expectLater(
        installLinuxUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: null,
          unpack: _fakeUnpack,
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );
    });

    test(
      'unpackWithTar strips the top-level directory of a real tarball',
      () async {
        final src = Directory('${root.path}/src/slim-m-client-0.90.0')
          ..createSync(recursive: true);
        File('${src.path}/slimm_app').writeAsStringSync('app');
        File('${src.path}/slim-m').writeAsStringSync('launcher');
        final archive = File('${root.path}/pkg.tar.gz');
        Process.runSync('tar', [
          '-C',
          '${root.path}/src',
          '-czf',
          archive.path,
          'slim-m-client-0.90.0',
        ]);
        final into = Directory('${root.path}/out')..createSync();
        await unpackWithTar(archive, into);
        expect(File('${into.path}/slimm_app').readAsStringSync(), 'app');
      },
      skip: !Platform.isLinux,
    );
  });

  group('confirmCleanStart', () {
    test('keeps current and previous, prunes older versions and leftovers', () {
      for (final v in ['0.85.0', '0.86.0', '0.89.0']) {
        _makeVersion(root, v);
      }
      Directory('${root.path}/.staging').createSync();
      Directory('${root.path}/.unpack-0.9.0').createSync();
      Directory('${root.path}/notes').createSync();
      _point(root, 'previous', '0.88.0');
      Link('${root.path}/current').deleteSync();
      _point(root, 'current', '0.89.0');
      File('${root.path}/pending').writeAsStringSync('0.89.0');
      File('${root.path}/pending.tries').writeAsStringSync('1');

      confirmCleanStart(layout);

      expect(_names(root), [
        '0.88.0',
        '0.89.0',
        'current',
        'notes',
        'previous',
      ]);
    });

    test('takeRollbackNotice reports once and clears the marker', () {
      File('${root.path}/rolled-back').writeAsStringSync('0.89.0\n');
      expect(takeRollbackNotice(layout), '0.89.0');
      expect(takeRollbackNotice(layout), isNull);
    });
  });

  group('the launcher', () {
    int run(String version) =>
        Process.runSync('sh', ['${root.path}/$version/slim-m']).exitCode;

    setUp(() {
      _makeVersion(
        root,
        '0.88.0',
        app: 'echo old > "\$(dirname "\$0")/../ran"',
      );
      _makeVersion(root, '0.89.0', app: 'exit 3');
      Link('${root.path}/current').deleteSync();
      _point(root, 'current', '0.89.0');
      _point(root, 'previous', '0.88.0');
      File('${root.path}/pending').writeAsStringSync('0.89.0');
    });

    test(
      'rolls back to previous once the new version fails to start twice',
      () {
        expect(run('0.89.0'), 3);
        expect(run('0.89.0'), 3);
        expect(_target(root, 'current'), '0.89.0');

        expect(run('0.89.0'), 0);
        expect(_target(root, 'current'), '0.88.0');
        expect(File('${root.path}/ran').existsSync(), isTrue);
        expect(
          File('${root.path}/rolled-back').readAsStringSync().trim(),
          '0.89.0',
        );
        expect(File('${root.path}/pending').existsSync(), isFalse);
        expect(takeRollbackNotice(layout), '0.89.0');
      },
    );

    test(
      'starts beside a running instance are not counted as failures',
      () async {
        _makeVersion(root, '0.89.0', app: 'sleep 5');
        final first = await Process.start('sh', ['${root.path}/0.89.0/slim-m']);
        addTearDown(first.kill);
        for (var i = 0; i < 40; i++) {
          if (File('${root.path}/running.pid').existsSync()) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        final beside = <Process>[];
        for (var i = 0; i < 3; i++) {
          beside.add(await Process.start('sh', ['${root.path}/0.89.0/slim-m']));
        }
        addTearDown(() {
          for (final p in beside) {
            p.kill();
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(_target(root, 'current'), '0.89.0');
        expect(File('${root.path}/rolled-back').existsSync(), isFalse);
      },
    );

    test('a start the app confirmed is never rolled back', () {
      expect(run('0.89.0'), 3);
      confirmCleanStart(layout);
      for (var i = 0; i < 4; i++) {
        expect(run('0.89.0'), 3);
      }
      expect(_target(root, 'current'), '0.89.0');
      expect(File('${root.path}/rolled-back').existsSync(), isFalse);
    });
  }, skip: !Platform.isLinux || !File(_launcherPath).existsSync());

  group('SelfUpdateController', () {
    ProviderContainer containerWith(FetchUpdate fetch) {
      final container = ProviderContainer(
        overrides: [
          selfUpdateProvider.overrideWith(
            (ref) => SelfUpdateController(
              ref,
              fetch: fetch,
              unpack: _fakeUnpack,
              newClient: http.Client.new,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'installs, stages the version and clears the installing flag',
      () async {
        final container = containerWith(
          ({
            required currentVersion,
            required platformKey,
            required stagingDir,
            required client,
          }) async => _update(root, '0.89.0'),
        );
        final version = await container
            .read(selfUpdateProvider)
            .install(
              currentVersion: '0.88.0',
              format: InstallFormat.tarball,
              resolvedExecutable: '${root.path}/0.88.0/slimm_app',
            );
        expect(version, '0.89.0');
        expect(container.read(stagedUpdateVersionProvider), '0.89.0');
        expect(container.read(selfUpdateInstallingProvider), isFalse);
        expect(container.read(selfUpdateFailureProvider), isNull);
      },
    );

    test(
      'a failed download lands in the failure state and installs nothing',
      () async {
        final container = containerWith(
          ({
            required currentVersion,
            required platformKey,
            required stagingDir,
            required client,
          }) async => throw const SelfUpdateFailure(
            SelfUpdateFailureKind.badSignature,
            'could not verify',
          ),
        );
        final version = await container
            .read(selfUpdateProvider)
            .install(
              currentVersion: '0.88.0',
              format: InstallFormat.tarball,
              resolvedExecutable: '${root.path}/0.88.0/slimm_app',
            );
        expect(version, isNull);
        expect(
          container.read(selfUpdateFailureProvider)?.kind,
          SelfUpdateFailureKind.badSignature,
        );
        expect(_target(root, 'current'), '0.88.0');
      },
    );

    test('rpm and flatpak never reach the network', () async {
      var fetched = false;
      final container = containerWith(({
        required currentVersion,
        required platformKey,
        required stagingDir,
        required client,
      }) async {
        fetched = true;
        return null;
      });
      for (final format in [InstallFormat.rpm, InstallFormat.flatpak]) {
        await container
            .read(selfUpdateProvider)
            .install(
              currentVersion: '0.88.0',
              format: format,
              resolvedExecutable: '${root.path}/0.88.0/slimm_app',
            );
        expect(
          container.read(selfUpdateFailureProvider)?.kind,
          SelfUpdateFailureKind.unsupportedInstall,
        );
      }
      expect(fetched, isFalse);
    });

    test('confirmStart reports a rollback and prunes after settling', () async {
      _makeVersion(root, '0.80.0');
      File('${root.path}/rolled-back').writeAsStringSync('0.89.0');
      final container = containerWith(
        ({
          required currentVersion,
          required platformKey,
          required stagingDir,
          required client,
        }) async => null,
      );
      await container
          .read(selfUpdateProvider)
          .confirmStart(
            resolvedExecutable: '${root.path}/0.88.0/slimm_app',
            settle: Duration.zero,
          );
      expect(
        container.read(selfUpdateFailureProvider)?.kind,
        SelfUpdateFailureKind.rolledBack,
      );
      expect(Directory('${root.path}/0.80.0').existsSync(), isFalse);
    });
  });

  test('detectLinuxLayout needs a version directory beside a current link', () {
    expect(
      detectLinuxLayout('${root.path}/0.88.0/slimm_app')?.root.path,
      root.path,
    );
    expect(detectLinuxLayout('/usr/lib/slim-m/slimm_app'), isNull);
    expect(detectLinuxLayout('${root.path}/nope/slimm_app'), isNull);
  });
}
