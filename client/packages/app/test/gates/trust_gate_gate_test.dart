// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file outside the api package that reads the session's access token must
/// ask the trust gate first, so the identity check (decision 0036) cannot be
/// skipped by a player or a socket that builds its own request.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

final _readsSessionToken = RegExp(r'session\.tokens\??\.accessToken');
final _asksGate = RegExp(r'\bawaitTrust\s*\(');

void main() {
  test('every file that reads the session token asks the trust gate', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final code = codeOnly(file.readAsStringSync());
      if (_readsSessionToken.hasMatch(code) && !_asksGate.hasMatch(code)) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('the gate sees the video sources that read the token', () {
    final readers = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            _readsSessionToken.hasMatch(codeOnly(file.readAsStringSync())))
          file.uri.pathSegments.last,
    ];
    expect(
      readers,
      containsAll([
        'attachment_video_source_io.dart',
        'attachment_video_source_web.dart',
      ]),
    );
  });
}
