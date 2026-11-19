// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/linux_install.dart'
    show Unpack;
import 'package:slimm_app/src/desktop/self_update/macos_install.dart';
import 'package:slimm_app/src/desktop/self_update/macos_layout.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_platform/platform.dart';

void _makeBundle(String path, String marker, {bool runnable = true}) {
  final exe = File('$path/Contents/MacOS/slimm_app')
    ..createSync(recursive: true)
    ..writeAsStringSync(marker);
  File('$path/Contents/Info.plist').writeAsStringSync('plist');
  if (runnable) Process.runSync('chmod', ['+x', exe.path]);
}

/// A bundle codesign accepts: a Mach-O executable and an Info.plist naming it.
void _makeSignableBundle(String path) {
  final exe = '$path/Contents/MacOS/slimm_app';
  Directory('$path/Contents/MacOS').createSync(recursive: true);
  File('/usr/bin/true').copySync(exe);
  Process.runSync('chmod', ['+x', exe]);
  File('$path/Contents/Info.plist').writeAsStringSync(_signablePlist);
}

const _signablePlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>slimm_app</string>
  <key>CFBundleIdentifier</key>
  <string>top.npcserver.slimm.selfupdatetest</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
''';

void _expectRan(ProcessResult done) =>
    expect(done.exitCode, 0, reason: '${done.stdout}${done.stderr}');

String _marker(String bundle) =>
    File('$bundle/Contents/MacOS/slimm_app').readAsStringSync();

Future<void> _unpackNew(File archive, Directory into) async =>
    _makeBundle('${into.path}/slimm_app.app', 'new');

Future<void> _accept(Directory bundle) async {}

VerifiedUpdate _update(Directory state, String version) {
  final file = File('${state.path}/.staging/pkg-$version.zip')
    ..createSync(recursive: true);
  return VerifiedUpdate.forTest(
    version: version,
    tag: 'client-v$version',
    file: file,
  );
}

void main() {
  late Directory root;
  late MacosInstallLayout layout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-macos-install-');
    _makeBundle('${root.path}/Applications/slim-m.app', 'old');
    layout = detectMacosLayout(
      '${root.path}/Applications/slim-m.app/Contents/MacOS/slimm_app',
      home: '${root.path}/home',
    )!;
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> install({
    Unpack unpack = _unpackNew,
    BundleCheck verify = _accept,
    InstallFormat format = InstallFormat.tarball,
    MacosInstallLayout? over,
    String version = '0.89.0',
  }) => installMacosUpdate(
    update: _update(layout.stateDir, version),
    format: format,
    layout: over ?? layout,
    unpack: unpack,
    verify: verify,
    stripQuarantine: _accept,
  );

  String? state(String name) {
    final file = File(layout.path(name));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  List<String> apps() => Directory(
    '${root.path}/Applications',
  ).listSync().map((e) => e.path.split('/').last).toList()..sort();

  group('installMacosUpdate', () {
    test('swaps the bundle in and keeps the old one aside', () async {
      await install();
      expect(_marker(layout.bundle.path), 'new');
      expect(_marker(layout.previousBundle.path), 'old');
      expect(state('pending'), '0.89.0');
      expect(apps(), ['.slim-m.app.previous', 'slim-m.app']);
    });

    test('an interrupted unpack leaves the current bundle untouched', () async {
      await expectLater(
        install(
          unpack: (archive, into) async {
            _makeBundle('${into.path}/slimm_app.app', 'half');
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
      expect(_marker(layout.bundle.path), 'old');
      expect(apps(), ['slim-m.app']);
      expect(state('pending'), isNull);
    });

    test('a zip without a runnable bundle of this app is refused', () async {
      for (final bad in <Unpack>[
        (a, into) async {},
        (a, into) async =>
            _makeBundle('${into.path}/slimm_app.app', 'x', runnable: false),
        (a, into) async {
          _makeBundle('${into.path}/one.app', 'x');
          _makeBundle('${into.path}/two.app', 'x');
        },
      ]) {
        await expectLater(
          install(unpack: bad),
          throwsA(isA<SelfUpdateFailure>()),
        );
        expect(_marker(layout.bundle.path), 'old');
        expect(apps(), ['slim-m.app']);
      }
    });

    test(
      'a bundle that fails the signature check is never swapped in',
      () async {
        await expectLater(
          install(
            verify: (_) async => throw const FileSystemException(
              'the bundle signature is invalid',
            ),
          ),
          throwsA(isA<SelfUpdateFailure>()),
        );
        expect(_marker(layout.bundle.path), 'old');
        expect(apps(), ['slim-m.app']);
      },
    );

    test('an earlier previous bundle is replaced, not stacked', () async {
      await install();
      _makeBundle('${root.path}/Applications/.slim-m.app.previous', 'stale');
      await install(version: '0.90.0');
      expect(_marker(layout.previousBundle.path), 'new');
      expect(apps(), ['.slim-m.app.previous', 'slim-m.app']);
    });

    test('refuses a non-tarball format or a missing layout', () async {
      await expectLater(
        installMacosUpdate(
          update: _update(layout.stateDir, '0.89.0'),
          format: InstallFormat.rpm,
          layout: layout,
        ),
        throwsA(
          isA<SelfUpdateFailure>().having(
            (f) => f.kind,
            'kind',
            SelfUpdateFailureKind.unsupportedInstall,
          ),
        ),
      );
      await expectLater(
        installMacosUpdate(
          update: _update(layout.stateDir, '0.89.0'),
          format: InstallFormat.tarball,
          layout: null,
        ),
        throwsA(isA<SelfUpdateFailure>()),
      );
      expect(_marker(layout.bundle.path), 'old');
    });

    test('refuses a bundle the user cannot write', () async {
      Process.runSync('chmod', ['a-w', layout.parent.path]);
      addTearDown(() => Process.runSync('chmod', ['u+w', layout.parent.path]));
      if (layout.isWritable) return;
      await expectLater(install(), throwsA(isA<SelfUpdateFailure>()));
      expect(_marker(layout.bundle.path), 'old');
    });
  });

  group('rollBackMacosIfStuck', () {
    setUp(() async => install());

    test('counts two starts, then the third restores the previous bundle', () {
      expect(rollBackMacosIfStuck(layout), isFalse);
      expect(rollBackMacosIfStuck(layout), isFalse);
      expect(state('pending.tries'), '2');
      expect(rollBackMacosIfStuck(layout), isTrue);
      expect(_marker(layout.bundle.path), 'old');
      expect(apps(), ['slim-m.app']);
      expect(state('pending'), isNull);
      expect(takeMacosRollbackNotice(layout), '0.89.0');
      expect(takeMacosRollbackNotice(layout), isNull);
    });

    test('does nothing once a start was confirmed', () {
      rollBackMacosIfStuck(layout);
      confirmMacosCleanStart(layout);
      for (var i = 0; i < 4; i++) {
        expect(rollBackMacosIfStuck(layout), isFalse);
      }
      expect(_marker(layout.bundle.path), 'new');
    });
  });

  group('confirmMacosCleanStart', () {
    test(
      'keeps the previous bundle before and after, and prunes the leftovers',
      () async {
        await install();
        File('${layout.stateDir.path}/.staging/leftover').createSync();
        expect(layout.previousBundle.existsSync(), isTrue);
        File('${layout.unpackDir.path}/half').createSync(recursive: true);
        confirmMacosCleanStart(layout);
        expect(apps(), ['.slim-m.app.previous', 'slim-m.app']);
        expect(_marker(layout.previousBundle.path), 'old');
        expect(_marker(layout.bundle.path), 'new');
        expect(state('pending'), isNull);
        expect(layout.stagingDir.existsSync(), isFalse);
      },
    );
  });

  group('detectMacosLayout', () {
    String? detect(String exe) =>
        detectMacosLayout(exe, home: '${root.path}/home')?.bundle.path;

    test('accepts a user-owned bundle and finds its state directory', () {
      expect(
        detect('${root.path}/Applications/slim-m.app/Contents/MacOS/slimm_app'),
        '${root.path}/Applications/slim-m.app',
      );
      expect(
        layout.stateDir.path,
        '${root.path}/home/Library/Application Support/slim-m/self-update',
      );
    });

    test('refuses managed locations, disk images and non-bundles', () {
      for (final exe in [
        '/System/Applications/Foo.app/Contents/MacOS/foo',
        '/Library/Foo.app/Contents/MacOS/foo',
        '/Volumes/slim-m/slim-m.app/Contents/MacOS/slimm_app',
        '/private/var/folders/x/AppTranslocation/y/d/slim-m.app/Contents/MacOS/slimm_app',
        '/Users/a/Library/Containers/x/Data/slim-m.app/Contents/MacOS/slimm_app',
        '${root.path}/build/slimm_app',
        '${root.path}/Applications/slim-m/Contents/MacOS/slimm_app',
      ]) {
        expect(detect(exe), isNull, reason: exe);
      }
    });

    test('refuses an App Store build', () {
      Directory(
        '${root.path}/Applications/slim-m.app/Contents/_MASReceipt',
      ).createSync();
      expect(
        detect('${root.path}/Applications/slim-m.app/Contents/MacOS/slimm_app'),
        isNull,
      );
    });
  });

  test(
    'ditto, xattr and codesign handle a real ad-hoc signed bundle',
    () async {
      final app = '${root.path}/real/slimm_app.app';
      _makeSignableBundle(app);
      _expectRan(Process.runSync('codesign', ['--force', '--sign', '-', app]));
      final zip = File('${root.path}/real.zip');
      _expectRan(
        Process.runSync('ditto', ['-c', '-k', '--keepParent', app, zip.path]),
      );
      final out = Directory('${root.path}/out')..createSync();
      await unpackWithDitto(zip, out);
      final unpacked = Directory('${out.path}/slimm_app.app');
      await verifySignature(unpacked);
      await clearQuarantine(unpacked);
      File('${unpacked.path}/Contents/Info.plist').writeAsStringSync('tamper');
      await expectLater(
        verifySignature(unpacked),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isMacOS ? false : 'needs ditto and codesign from macOS',
  );
}
