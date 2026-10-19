// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/install_fs.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/windows_adopt.dart';
import 'package:slimm_app/src/desktop/self_update/windows_layout.dart';

String? _read(Directory root, String name) {
  final file = File('${root.path}/$name');
  return file.existsSync() ? file.readAsStringSync() : null;
}

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
  late Directory temp;
  late Directory bundle;
  late Directory root;
  late String executable;
  late List<File> shortcuts;

  Future<void> fakeShortcut(File launcher) async => shortcuts.add(launcher);

  Future<WindowsInstallLayout> adopt({String version = '0.90.0'}) =>
      adoptWindowsInstall(
        executable: executable,
        version: version,
        root: root,
        createShortcut: fakeShortcut,
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('slimm-windows-adopt-');
    bundle = Directory('${temp.path}/unzipped')..createSync();
    Directory('${bundle.path}/data/flutter_assets').createSync(recursive: true);
    File('${bundle.path}/slimm_app.exe').writeAsStringSync('app');
    File('${bundle.path}/slim-m.exe').writeAsStringSync('launcher');
    File('${bundle.path}/data/flutter_assets/a.bin').writeAsStringSync('a');
    executable = '${bundle.path}/slimm_app.exe';
    root = Directory('${temp.path}/local/slim-m');
    shortcuts = [];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('writes the layout the updater and launcher expect', () async {
    final layout = await adopt();

    expect(layout.root.path, root.path);
    expect(_read(root, 'current'), '0.90.0');
    expect(_read(root, 'previous'), isNull);
    expect(_read(root, 'slim-m.exe'), 'launcher');
    expect(_read(root, 'app-0.90.0/slimm_app.exe'), 'app');
    expect(_read(root, 'app-0.90.0/data/flutter_assets/a.bin'), 'a');
    expect(shortcuts.single.path, layout.launcher.path);
    expect(
      root.listSync().map(
        (e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ),
      unorderedEquals(['app-0.90.0', 'slim-m.exe', 'current']),
    );
    expect(File('${bundle.path}/slimm_app.exe').existsSync(), isTrue);
  });

  test('is idempotent when run again', () async {
    await adopt();
    await adopt();

    expect(_read(root, 'current'), '0.90.0');
    expect(_read(root, 'previous'), isNull);
    expect(_read(root, 'app-0.90.0/slimm_app.exe'), 'app');
  });

  test('keeps the version it replaces as previous', () async {
    Directory('${root.path}/app-0.89.0').createSync(recursive: true);
    File('${root.path}/current').writeAsStringSync('0.89.0');

    await adopt();

    expect(_read(root, 'previous'), '0.89.0');
    expect(_read(root, 'current'), '0.90.0');
    expect(Directory('${root.path}/app-0.89.0').existsSync(), isTrue);
  });

  test('a detected layout results from the adopted install', () async {
    await adopt();
    final adopted = '${root.path}/app-0.90.0/slimm_app.exe';

    expect(detectWindowsLayout(adopted)?.root.path, root.path);
    expect(canAdoptWindowsInstall(adopted), isFalse);
  });

  test('refuses a system install path and writes nothing', () async {
    final system = Directory('${temp.path}/Program Files/slim-m')
      ..createSync(recursive: true);
    File('${system.path}/slimm_app.exe').writeAsStringSync('app');
    File('${system.path}/slim-m.exe').writeAsStringSync('launcher');
    executable = '${system.path}/slimm_app.exe';

    await expectLater(
      adopt(),
      throwsA(
        isA<SelfUpdateFailure>().having(
          (e) => e.kind,
          'kind',
          SelfUpdateFailureKind.unsupportedInstall,
        ),
      ),
    );
    expect(root.existsSync(), isFalse);
  });

  test('refuses a bundle without a launcher', () async {
    File('${bundle.path}/slim-m.exe').deleteSync();

    expect(canAdoptWindowsInstall(executable), isFalse);
    await expectLater(adopt(), throwsA(isA<SelfUpdateFailure>()));
  });

  test('a failing shortcut leaves no pointer behind', () async {
    await expectLater(
      adoptWindowsInstall(
        executable: executable,
        version: '0.90.0',
        root: root,
        createShortcut: (_) async =>
            throw const ProcessException('powershell', [], 'denied', 1),
      ),
      throwsA(
        isA<SelfUpdateFailure>().having(
          (e) => e.kind,
          'kind',
          SelfUpdateFailureKind.installFailed,
        ),
      ),
    );
    expect(_read(root, 'current'), isNull);
  });

  test('retries a directory rename a scanner is holding', () async {
    final calls = <int>[];
    await adoptWindowsInstall(
      executable: executable,
      version: '0.90.0',
      root: root,
      createShortcut: fakeShortcut,
      rename: _lockedFor(2, calls),
      backoff: _noWait,
    );
    expect(calls, hasLength(3));
    expect(_read(root, 'current'), '0.90.0');
  });
}
