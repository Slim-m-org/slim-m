// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser save of an extensionless or empty file goes out and counts as saved.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/download_target.dart';

void main() {
  test('names without an extension get .bin, others are kept', () {
    expect(webSaveName('Makefile'), 'Makefile.bin');
    expect(webSaveName('.env'), '.env.bin');
    expect(webSaveName('notes.'), 'notes..bin');
    expect(webSaveName('a/b/report.pdf'), 'report.pdf');
    expect(webSaveName(''), 'download.bin');
  });

  test(
    'an extensionless file saves under a default extension and reports saved',
    () async {
      final saves = <(List<int>, String)>[];
      final target = BrowserDownloadTarget(
        'LICENSE',
        (bytes, name) => saves.add((bytes, name)),
      );
      await target.write([1, 2, 3]);

      expect(await target.finish(), isTrue);
      expect(saves.single.$2, 'LICENSE.bin');
      expect(saves.single.$1, [1, 2, 3]);
    },
  );

  test('a zero-byte file still saves and reports saved', () async {
    final saves = <Uint8List>[];
    final target = BrowserDownloadTarget(
      'empty.txt',
      (bytes, _) => saves.add(bytes),
    );

    expect(await target.finish(), isTrue);
    expect(saves.single, isEmpty);
  });
}
