// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/linux_install.dart';
import 'package:slimm_app/src/desktop/self_update/linux_layout.dart';

void _makeVersion(Directory root, String version) {
  final dir = Directory('${root.path}/$version')..createSync(recursive: true);
  File('${dir.path}/slimm_app').writeAsStringSync('#!/bin/sh\nexit 0\n');
  File('${dir.path}/slim-m').writeAsStringSync('#!/bin/sh\nexit 0\n');
}

void _point(Directory root, String link, String version) =>
    Link('${root.path}/$link').createSync(version);

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
    root = Directory.systemTemp.createTempSync('slimm-linux-clean-');
    _makeVersion(root, '0.88.0');
    _point(root, 'current', '0.88.0');
    layout = LinuxInstallLayout(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

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

      confirmCleanStart(layout, '/elsewhere/slimm_app');

      expect(_names(root), [
        '0.88.0',
        '0.89.0',
        'current',
        'notes',
        'previous',
      ]);
    });

    test('prunes nothing when the current pointer cannot be read', () {
      _makeVersion(root, '0.80.0');
      Link('${root.path}/current').deleteSync();

      confirmCleanStart(layout, '/elsewhere/slimm_app');

      expect(Directory('${root.path}/0.80.0').existsSync(), isTrue);
      expect(Directory('${root.path}/0.88.0').existsSync(), isTrue);
    });

    test(
      'prunes nothing when the previous pointer is there but unreadable',
      () {
        _makeVersion(root, '0.80.0');
        File('${root.path}/previous').writeAsStringSync('not a link');

        confirmCleanStart(layout, '/elsewhere/slimm_app');

        expect(Directory('${root.path}/0.80.0').existsSync(), isTrue);
      },
    );

    test('never prunes the folder the running executable lives in', () {
      _makeVersion(root, '0.80.0');
      _makeVersion(root, '0.89.0');
      Link('${root.path}/current').deleteSync();
      _point(root, 'current', '0.89.0');

      confirmCleanStart(layout, '${root.path}/0.80.0/slimm_app');

      expect(Directory('${root.path}/0.80.0').existsSync(), isTrue);
      expect(Directory('${root.path}/0.88.0').existsSync(), isFalse);
    });

    test('takeRollbackNotice reports once and clears the marker', () {
      File('${root.path}/rolled-back').writeAsStringSync('0.89.0\n');
      expect(takeRollbackNotice(layout), '0.89.0');
      expect(takeRollbackNotice(layout), isNull);
    });
  });
}
