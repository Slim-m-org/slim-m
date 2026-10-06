// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A percent escape that is not valid UTF-8 is not a link, never an exception.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/invite_link.dart';
import 'package:slimm_app/src/message_link.dart';

void main() {
  test('parseInviteLink returns null for a non-utf8 percent escape', () {
    expect(parseInviteLink('slimm://join?server=%ff&code=x'), isNull);
  });

  test('parseMessageLink returns null for a non-utf8 percent escape', () {
    expect(
      parseMessageLink('slimm://message?server=%ff&channel=a&id=b'),
      isNull,
    );
  });

  test('a well formed link still parses', () {
    expect(
      parseInviteLink('slimm://join?server=https%3A%2F%2Fa.example&code=x'),
      isNotNull,
    );
  });
}
