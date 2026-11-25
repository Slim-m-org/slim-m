// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a copied file is staged, how it is named, and that a copy never fails
/// on what an earlier one left behind.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:slimm_platform/platform.dart';

void main() {
  group('safeFileName', () {
    const table = <String, String>{
      'photo.png': 'photo.png',
      'a/b\\c.txt': 'a_b_c.txt',
      'what?*.txt': 'what__.txt',
      'nul.png': '_nul.png',
      'AUX.txt': '_AUX.txt',
      'com1': '_com1',
      'LPT9.tar.gz': '_LPT9.tar.gz',
      'nul .txt': '_nul .txt',
      'console.txt': 'console.txt',
      'report.': 'report',
      'report. . ': 'report',
      '..': 'file',
      '.': 'file',
      '': 'file',
      '   ': 'file',
      '.hidden': '.hidden',
      'tab\tname.txt': 'tab_name.txt',
    };
    table.forEach((input, expected) {
      test('"$input" becomes "$expected"', () {
        expect(safeFileName(input), expected);
      });
    });

    test('a long name is cut to a byte budget and keeps its extension', () {
      final name = safeFileName('${'é' * 300}.mp4');
      expect(name.endsWith('.mp4'), isTrue);
      expect(utf8.encode(name).length, lessThan(256));
    });
  });

  group('clipboardStagingRoot', () {
    Future<String> temp() async => '/tmp/dart-temp';

    test('a flatpak stages where the host sees the same path', () async {
      final dir = await clipboardStagingRoot(
        env: {'XDG_RUNTIME_DIR': '/run/user/1000', 'FLATPAK_ID': 'top.x.Slimm'},
        tempPath: temp,
        isLinux: true,
      );
      expect(dir.path, '/run/user/1000/app/top.x.Slimm/slimm-clipboard');
    });

    test('a native Linux install stays out of the shared /tmp', () async {
      final dir = await clipboardStagingRoot(
        env: {'XDG_RUNTIME_DIR': '/run/user/1000'},
        tempPath: temp,
        isLinux: true,
      );
      expect(dir.path, '/run/user/1000/slimm-clipboard');
    });

    test('without a runtime dir, or off Linux, the temp dir is used', () async {
      for (final linux in [true, false]) {
        final dir = await clipboardStagingRoot(
          env: {'FLATPAK_ID': 'top.x.Slimm'},
          tempPath: temp,
          isLinux: linux,
        );
        expect(dir.path, '/tmp/dart-temp/slimm-clipboard');
      }
      final windows = await clipboardStagingRoot(
        env: {'XDG_RUNTIME_DIR': '/run/user/1'},
        tempPath: temp,
        isLinux: false,
      );
      expect(windows.path, '/tmp/dart-temp/slimm-clipboard');
    });
  });

  group('stageClipboardFile', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('slimm-stage'));
    tearDown(() {
      for (final e in root.listSync(recursive: true)) {
        if (e is Directory) Process.runSync('chmod', ['755', e.path]);
      }
      root.deleteSync(recursive: true);
    });

    final bytes = Uint8List.fromList([1, 2, 3]);

    test('writes the bytes under the sanitized name', () async {
      final file = await stageClipboardFile(root, bytes, 'nul.png');
      expect(p.basename(file.path), '_nul.png');
      expect(file.readAsBytesSync(), bytes);
      expect(p.dirname(p.dirname(file.path)), root.path);
    });

    test('each copy gets its own folder and older ones are swept', () async {
      final first = await stageClipboardFile(root, bytes, 'a.mp4');
      final second = await stageClipboardFile(root, bytes, 'a.mp4');
      expect(second.parent.path, isNot(first.parent.path));
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);
    });

    test('an earlier copy that cannot be deleted does not fail the next',
        () async {
      final first = await stageClipboardFile(root, bytes, 'a.mp4');
      Process.runSync('chmod', ['555', first.parent.path]);
      final second = await stageClipboardFile(root, bytes, 'b.mp4');
      expect(second.existsSync(), isTrue);
      expect(first.existsSync(), isTrue);
    }, skip: Platform.isWindows ? 'needs POSIX permissions' : false);
  });
}
