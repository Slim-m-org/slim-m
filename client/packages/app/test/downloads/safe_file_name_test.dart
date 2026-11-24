// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// File names from other people become one safe path segment.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/safe_file_name.dart';
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';

void main() {
  const windowsCases = {
    'a:b.txt': 'a_b.txt',
    'what?.png': 'what_.png',
    'a<b>c|d*e"f.txt': 'a_b_c_d_e_f.txt',
    'tab\tname.txt': 'tab_name.txt',
    'report. . ': 'report',
    'CON': '_CON',
    'nul.txt': '_nul.txt',
    'com1.tar.gz': '_com1.tar.gz',
    'LPT9.log': '_LPT9.log',
    'console.txt': 'console.txt',
    '../up/x.txt': 'x.txt',
    r'C:\evil\x.txt': 'x.txt',
    '..': 'download',
    '': 'download',
  };
  for (final entry in windowsCases.entries) {
    test('windows: "${entry.key}" -> "${entry.value}"', () {
      expect(safeFileName(entry.key, windows: true), entry.value);
    });
  }

  test('linux keeps characters that only windows forbids', () {
    expect(safeFileName('a:b?.txt', windows: false), 'a:b?.txt');
    expect(safeFileName('nul', windows: false), 'nul');
    expect(safeFileName('a\u0000b', windows: false), 'a_b');
    expect(safeFileName('a/b.txt', windows: false), 'b.txt');
  });

  test(
    'a long non-ascii name is cut on a code point and keeps its extension',
    () {
      final name = '${'\u{1F600}\u00e9\u6f22' * 80}.png';
      for (final windows in [false, true]) {
        final out = safeFileName(name, windows: windows);
        expect(out.endsWith('.png'), isTrue);
        expect(utf8.encode('$out (99).part').length, lessThanOrEqualTo(255));
        expect(utf8.decode(utf8.encode(out)), out);
      }
    },
  );

  test('an enormous extension is cut too', () {
    final out = safeFileName('a.${'x' * 400}', windows: false);
    expect(utf8.encode(out).length, lessThanOrEqualTo(240));
  });

  test('a theme named like a device is not a reserved file name', () {
    expect(themeFileName('CON'), '_con.slimm-theme.json');
    expect(themeFileName('Aux'), '_aux.slimm-theme.json');
    expect(themeFileName('Night Owl'), 'night-owl.slimm-theme.json');
  });
}
