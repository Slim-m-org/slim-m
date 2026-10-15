// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An AnimatedSize given a zero duration under reduced motion can assert
/// mid-layout; `AppMotion.reducedSize` exists for it (issue 2034).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

void main() {
  test('no AnimatedSize takes the zero-duration reduced motion helper', () {
    final offenders = <String>[];
    final call = RegExp(
      r'AnimatedSize\(\s*(?:[a-zA-Z]+:[^,]*,\s*)*?duration:\s*AppMotion\.reduced\(',
    );
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final code = codeOnly(entity.readAsStringSync());
      for (final match in call.allMatches(code)) {
        final line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use AppMotion.reducedSize for an AnimatedSize',
    );
  });
}
