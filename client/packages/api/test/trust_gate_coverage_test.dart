// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file that reads the session's tokens must also ask the trust gate, so a
/// new way of sending the session cannot skip the identity check.
@TestOn('vm')
library;

import 'dart:io';

import 'package:slimm_test_support/source_gates.dart';
import 'package:test/test.dart';

/// Defines or compares the tokens; nothing in these sends them.
const _holders = {'models.dart', 'session_store.dart'};

final _readsTokens = RegExp(r'\b(accessToken|refreshToken)\b');
final _asksGate = RegExp(r'\b(awaitTrust|trustGate)\b');

void main() {
  test('every file that reads the session tokens asks the trust gate', () {
    final offenders = <String>[];
    for (final file in Directory('lib/src').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final name = file.uri.pathSegments.last;
      if (_holders.contains(name)) continue;
      final code = codeOnly(file.readAsStringSync());
      if (_readsTokens.hasMatch(code) && !_asksGate.hasMatch(code)) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
