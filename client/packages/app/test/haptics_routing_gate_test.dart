// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every haptic goes through `AppHaptics`, which holds the phone-only guard
/// and the person's haptics switch; a raw `HapticFeedback` call bypasses both.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

void main() {
  test('no app source calls HapticFeedback directly', () {
    final offenders = [
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')))
        if (codeOnly(file.readAsStringSync()).contains('HapticFeedback.'))
          file.path,
    ];
    expect(offenders, isEmpty);
  });
}
