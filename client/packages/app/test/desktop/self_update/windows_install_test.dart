// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/install_fs.dart';
import 'package:slimm_app/src/desktop/self_update/linux_install.dart'
    show Unpack;
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/windows_install.dart';
import 'package:slimm_app/src/desktop/self_update/windows_layout.dart';
import 'package:slimm_platform/platform.dart';

void _makeVersion(Directory root, String version) {
  Directory('${root.path}/app-$version').createSync(recursive: true);
  File('${root.path}/app-$version/slimm_app.exe').writeAsStringSync(version);
}

void _pointer(Directory root, String name, String version) =>
    File('${root.path}/$name').writeAsStringSync(version);

String? _read(Directory root, String name) {
  final file = File('${root.path}/$name');
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<void> _fakeUnpack(File archive, Directory into) async =>
    File('${into.path}/slimm_app.exe').writeAsStringSync('new');

VerifiedUpdate _update(Directory root, String version) {
  final file = File('${root.path}/.staging/pkg-$version.zip')
    ..createSync(recursive: true);
  return VerifiedUpdate.forTest(
    version: version,
    tag: 'client-v$version',
    file: file,
  );
}

List<String> _names(Directory root) =>
    root
        .listSync()
        .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList()
      ..sort();

Future<void> _install(
  Directory root, {
  String version = '0.89.0',
  Unpack unpack = _fakeUnpack,
}) => installWindowsUpdate(
  update: _update(root, version),
  format: InstallFormat.tarball,
  layout: WindowsInstallLayout(root),
  unpack: unpack,
);

RenameDirectory _lockedFor(int times, List<int> calls, {int code = 32}) {
  return (from, to) async {
    calls.add(calls.length);
    if (calls.length <= times) {
      throw FileSystemException('locked', from.path, OSError('', code));
    }
    await from.rename(to);
  };
}

const _noWait = [Duration.zero, Duration.zero, Duration.zero];

void main() {
  late Directory root;
  late WindowsInstallLayout layout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-windows-install-');
    _makeVersion(root, '0.88.0');
    File('${root.path}/slim-m.exe').writeAsStringSync('launcher');
    _pointer(root, 'current', '0.88.0');
    layout = WindowsInstallLayout(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('installWindowsUpdate', () {
    test(
      'publishes the folder, swaps the pointer and keeps the old version',
      () async {
        await _install(root);
        expect(_read(root, 'current'), '0.89.0');
        expect(_read(root, 'previous'), '0.88.0');
        expect(_read(root, 'pending'), '0.89.0');
        expect(
          File('${root.path}/app-0.89.0/slimm_app.exe').existsSync(),
          isTrue,
        );
        expect(Directory('${root.path}/app-0.88.0').existsSync(), isTrue);
        expect(
          _names(root).where((n) => n.startsWith('.') && n != '.staging'),
          isEmpty,
        );
      },
    );

    test(
      'an interrupted unpack leaves the pointer and the old version alone',
      () async {
        Future<void> dies(File archive, Directory into) async {
          File('${into.path}/half.dll').writeAsStringSync('partial');
          throw const FileSystemException('disk full');
        }

        await expectLater(
          _install(root, unpack: dies),
          throwsA(isA<SelfUpdateFailure>()),
        );
        expect(_read(root, 'current'), '0.88.0');
        expect(_read(root, 'previous'), isNull);
        expect(_read(root, 'pending'), isNull);
        expect(Directory('${root.path}/app-0.89.0').existsSync(), isFalse);
        expect(Directory('${root.path}/.unpack-0.89.0').existsSync(), isFalse);
        expect(
          File('${root.path}/app-0.88.0/slimm_app.exe').existsSync(),
          isTrue,
        );
      },
    );

    test('a zip without the app is not published', () async {
      Future<void> empty(File archive, Directory into) async =>
          File('${into.path}/readme.txt').writeAsStringSync('x');
      await expectLater(
        _install(root, unpack: empty),
        throwsA(
          isA<SelfUpdateFailure>().having(
            (f) => f.kind,
            'kind',
            SelfUpdateFailureKind.installFailed,
          ),
        ),
      );
      expect(_read(root, 'current'), '0.88.0');
      expect(Directory('${root.path}/app-0.89.0').existsSync(), isFalse);
    });

    test('a rewritten pointer is never a half-written file', () async {
      await _install(root);
      await _install(root, version: '0.90.0');
      for (final name in ['current', 'previous']) {
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(_read(root, name)!), isTrue);
      }
      expect(_read(root, 'current'), '0.90.0');
      expect(_read(root, 'previous'), '0.89.0');
    });

    test('a layout that is missing or the wrong format refuses', () async {
      for (final failure in [
        installWindowsUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: null,
          unpack: _fakeUnpack,
        ),
        installWindowsUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.rpm,
          layout: layout,
          unpack: _fakeUnpack,
        ),
      ]) {
        await expectLater(
          failure,
          throwsA(
            isA<SelfUpdateFailure>().having(
              (f) => f.kind,
              'kind',
              SelfUpdateFailureKind.unsupportedInstall,
            ),
          ),
        );
      }
      expect(_read(root, 'current'), '0.88.0');
    });
  });

  group('confirmWindowsCleanStart', () {
    test('keeps current and previous, prunes older folders and leftovers', () {
      for (final v in ['0.80.0', '0.87.0']) {
        _makeVersion(root, v);
      }
      _makeVersion(root, '0.89.0');
      _pointer(root, 'current', '0.89.0');
      _pointer(root, 'previous', '0.88.0');
      _pointer(root, 'pending', '0.89.0');
      _pointer(root, 'pending.tries', '1');
      Directory('${root.path}/.unpack-0.90.0').createSync();
      Directory('${root.path}/.staging').createSync();

      confirmWindowsCleanStart(layout);

      expect(_names(root), [
        'app-0.88.0',
        'app-0.89.0',
        'current',
        'previous',
        'slim-m.exe',
      ]);
    });

    test('takeWindowsRollbackNotice reports once and clears the marker', () {
      _pointer(root, 'rolled-back', '0.89.0\n');
      expect(takeWindowsRollbackNotice(layout), '0.89.0');
      expect(takeWindowsRollbackNotice(layout), isNull);
    });
  });

  group('detectWindowsLayout', () {
    test(
      'needs a version folder beside the launcher and a current pointer',
      () {
        final exe = '${root.path}/app-0.88.0/slimm_app.exe';
        expect(detectWindowsLayout(exe)?.root.path, root.path);
        expect(detectWindowsLayout('${root.path}/nope/slimm_app.exe'), isNull);
        File('${root.path}/slim-m.exe').deleteSync();
        expect(detectWindowsLayout(exe), isNull);
      },
    );

    test('a machine-wide or MSIX install is never the per-user layout', () {
      for (final base in [
        'C:/Program Files/slim-m',
        'C:/Program Files (x86)/slim-m',
        r'C:\Program Files\WindowsApps\Slimm_1.0_x64__abc',
      ]) {
        expect(detectWindowsLayout('$base/app-0.88.0/slimm_app.exe'), isNull);
      }
      final local = Directory('${root.path}/Program Files/slim-m')
        ..createSync(recursive: true);
      _makeVersion(local, '0.88.0');
      File('${local.path}/slim-m.exe').writeAsStringSync('x');
      _pointer(local, 'current', '0.88.0');
      expect(
        detectWindowsLayout('${local.path}/app-0.88.0/slimm_app.exe'),
        isNull,
      );
    });
  });

  group('a directory rename held by a scanner', () {
    test('is retried until the lock lets go', () async {
      final calls = <int>[];
      await installWindowsUpdate(
        update: _update(root, '0.89.0'),
        format: InstallFormat.tarball,
        layout: layout,
        unpack: _fakeUnpack,
        rename: _lockedFor(2, calls),
        backoff: _noWait,
      );
      expect(calls, hasLength(3));
      expect(_read(root, 'current'), '0.89.0');
    });

    test(
      'that never lets go fails the install and keeps the old version',
      () async {
        final calls = <int>[];
        await expectLater(
          installWindowsUpdate(
            update: _update(root, '0.89.0'),
            format: InstallFormat.tarball,
            layout: layout,
            unpack: _fakeUnpack,
            rename: _lockedFor(99, calls),
            backoff: _noWait,
          ),
          throwsA(
            isA<SelfUpdateFailure>().having(
              (e) => e.kind,
              'kind',
              SelfUpdateFailureKind.installFailed,
            ),
          ),
        );
        expect(calls, hasLength(_noWait.length + 1));
        expect(_read(root, 'current'), '0.88.0');
      },
    );

    test('with another error is not retried', () async {
      final calls = <int>[];
      await expectLater(
        installWindowsUpdate(
          update: _update(root, '0.89.0'),
          format: InstallFormat.tarball,
          layout: layout,
          unpack: _fakeUnpack,
          rename: _lockedFor(99, calls, code: 2),
          backoff: _noWait,
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );
      expect(calls, hasLength(1));
    });
  });

  group('unpackZip', () {
    File zipOf(Map<String, String> files) {
      final archive = Archive();
      files.forEach(
        (name, text) => archive.addFile(ArchiveFile.string(name, text)),
      );
      return File('${root.path}/pkg.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
    }

    test('extracts nested files into the destination', () async {
      final into = Directory('${root.path}/out')..createSync();
      await unpackZip(
        zipOf({'slimm_app.exe': 'exe', 'data/app.so': 'so'}),
        into,
      );
      expect(File('${into.path}/slimm_app.exe').readAsStringSync(), 'exe');
      expect(File('${into.path}/data/app.so').readAsStringSync(), 'so');
    });

    test(
      'an entry that climbs out of the destination fails the unpack',
      () async {
        final into = Directory('${root.path}/out')..createSync();
        await expectLater(
          unpackZip(zipOf({'../escaped.txt': 'x'}), into),
          throwsA(isA<FileSystemException>()),
        );
        expect(File('${root.path}/escaped.txt').existsSync(), isFalse);
      },
    );
  });
}
