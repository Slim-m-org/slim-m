// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share capture reads its source from the environment, which only the
/// Linux runner may set, and only before any thread exists.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/share_audio_isolation.dart';

String _withoutComments(String source) => source
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'//.*'), ''))
    .join('\n');

void main() {
  test('the runner exports the mix monitor as the share capture source', () {
    final main = File('../app/linux/runner/main.cc').readAsStringSync();

    expect(
      _withoutComments(main),
      contains('setenv("SLIMM_SHARE_AUDIO_SOURCE", "$shareMixSource", 1);'),
    );
  });

  test('no Dart code changes the environment while the app runs', () {
    final offenders = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            RegExp(r"SLIMM_SHARE_AUDIO_SOURCE")
                .hasMatch(_withoutComments(file.readAsStringSync())))
          file.path,
    ];

    expect(offenders, isEmpty);
  });
}
