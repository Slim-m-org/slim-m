// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every loading indicator in the client is an [AppSpinner], so size, ink and
/// reduce-motion behaviour stay in one place.
///
/// Reads comment- and string-stripped source, never raw text, so a doc
/// comment naming the widget is not a use of it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

const _home = 'lib/src/components/core/spinner.dart';

/// Shrink-only: a file may leave this set, never join it.
const _allowed = <String>{};

final _raw = RegExp(r'\bCircularProgressIndicator\b');

Iterable<File> _clientSources() sync* {
  for (final pkg in Directory('..').listSync().whereType<Directory>()) {
    final lib = Directory('${pkg.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) yield file;
    }
  }
}

String _relative(File file) => file.path.replaceFirst('../', '');

void main() {
  test('no raw CircularProgressIndicator outside AppSpinner', () {
    final offenders = <String>[];
    for (final file in _clientSources()) {
      final path = _relative(file);
      if (path == 'design_system/$_home' || _allowed.contains(path)) continue;
      final hits = _raw.allMatches(codeOnly(file.readAsStringSync())).length;
      if (hits > 0) offenders.add('$path: $hits');
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use AppSpinner from the design system:\n${offenders.join('\n')}',
    );
  });

  test('the allowlist holds no file that no longer needs it', () {
    for (final path in _allowed) {
      final source = File('../$path').readAsStringSync();
      expect(_raw.hasMatch(codeOnly(source)), isTrue, reason: '$path is clean');
    }
  });

  test('the scrubber ignores comments and strings but sees code', () {
    expect(_raw.hasMatch(codeOnly('// CircularProgressIndicator()')), isFalse);
    expect(_raw.hasMatch(codeOnly("'CircularProgressIndicator'")), isFalse);
    expect(
        _raw.hasMatch(codeOnly('child: CircularProgressIndicator(),')), isTrue);
  });
}
