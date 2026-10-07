// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pending marker is what arms the three-start rollback, so it is written
/// before the bundle swap: a marker failure must leave the old bundle live.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/macos_install.dart';
import 'package:slimm_app/src/desktop/self_update/macos_layout.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_platform/platform.dart';

void _makeBundle(String path, String marker) {
  final exe = File('$path/Contents/MacOS/slimm_app')
    ..createSync(recursive: true)
    ..writeAsStringSync(marker);
  File('$path/Contents/Info.plist').writeAsStringSync('plist');
  Process.runSync('chmod', ['+x', exe.path]);
}

String _marker(String bundle) =>
    File('$bundle/Contents/MacOS/slimm_app').readAsStringSync();

void main() {
  test(
    'a failed pending-marker write must not leave the new bundle live',
    () async {
      final root = Directory.systemTemp.createTempSync('slimm-audit-');
      addTearDown(() => root.deleteSync(recursive: true));
      _makeBundle('${root.path}/Applications/slim-m.app', 'old');
      final layout = detectMacosLayout(
        '${root.path}/Applications/slim-m.app/Contents/MacOS/slimm_app',
        home: '${root.path}/home',
      )!;
      final file = File('${layout.stateDir.path}/.staging/pkg.zip')
        ..createSync(recursive: true);
      final update = VerifiedUpdate.forTest(
        version: '0.89.0',
        tag: 'client-v0.89.0',
        file: file,
      );
      SelfUpdateFailure? failure;
      try {
        await installMacosUpdate(
          update: update,
          format: InstallFormat.tarball,
          layout: layout,
          unpack: (a, into) async {
            _makeBundle('${into.path}/slimm_app.app', 'new');
            // a directory where the marker file goes makes the write throw
            Directory(
              layout.path(MacosNames.pending),
            ).createSync(recursive: true);
          },
          verify: (_) async {},
          stripQuarantine: (_) async {},
        );
      } on SelfUpdateFailure catch (e) {
        failure = e;
      }
      expect(failure, isNotNull);
      expect(failure!.message, contains('unchanged'));
      // the failure says unchanged, so the live bundle must still be the old one
      expect(_marker(layout.bundle.path), 'old');
    },
  );
}
