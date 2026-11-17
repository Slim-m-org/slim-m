// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The doubled-name rule the semantics gates apply: what a screen reader
/// would announce twice, and what only looks alike.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/semantics_audit.dart';

void main() {
  test('a tooltip the label already says is doubled', () {
    expect(doubledName('Mute', 'Mute'), 'Mute');
    expect(doubledName('Call Ada', 'Call'), 'Call');
    expect(doubledName('Mute', 'Mute (Ctrl+Shift+M)'), 'Mute (Ctrl+Shift+M)');
  });

  test('a merged text or hint repeating the part before it is doubled', () {
    expect(
      doubledName('Search settings\nSearch settings', ''),
      'Search settings',
    );
    expect(doubledName('Closes, currently Never\nNever', ''), 'Never');
    expect(
      doubledName(
        'Join the official Space. host\nJoin the official Space\nhost',
        '',
      ),
      'Join the official Space',
    );
  });

  test('different parts or a bare count are not', () {
    expect(doubledName('Message\nMessage composer', ''), isNull);
    expect(doubledName('Reported user\nSubject\nReported', ''), isNull);
    expect(doubledName('3\n3', ''), isNull);
  });
}
