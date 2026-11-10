// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bare `dart:io` `Platform.isX` probe throws on the web build, so app code
/// asks `slimm_platform` instead; only the native-only files below probe it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

/// Shrink-only: a file leaves this list once it goes through `slimm_platform`.
const _nativeOnly = {
  'lib/src/desktop/display_server.dart',
  'lib/src/desktop/self_update/update_download.dart',
  'lib/src/desktop/startup_updates.dart',
  'lib/src/downloads/download_target_io.dart',
};

final _platformProbe = RegExp(r'\bPlatform\s*\.\s*is[A-Z]');

void main() {
  final readers = {
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')))
      if (_platformProbe.hasMatch(codeOnly(file.readAsStringSync()))) file.path,
  };

  test('only native-only files probe dart:io Platform directly', () {
    expect(readers.difference(_nativeOnly), isEmpty);
  });

  test('the native-only list holds no file that stopped probing Platform', () {
    expect(_nativeOnly.difference(readers), isEmpty);
  });
}
