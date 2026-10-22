// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [messageMentionsUsername].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_mentions.dart';

void main() {
  test('a plain mention of the username matches', () {
    expect(messageMentionsUsername('hey @nick, look at this', 'nick'), isTrue);
  });

  test('matching is case-insensitive', () {
    expect(messageMentionsUsername('hey @Nick', 'nick'), isTrue);
  });

  test('a mention of somebody else does not match', () {
    expect(messageMentionsUsername('hey @alice', 'nick'), isFalse);
  });

  test('no mention at all does not match', () {
    expect(messageMentionsUsername('just talking', 'nick'), isFalse);
  });

  test('a mention nested inside bold is still found', () {
    expect(messageMentionsUsername('**ping @nick**', 'nick'), isTrue);
  });

  test('a mention nested inside a spoiler is still found', () {
    expect(messageMentionsUsername('||cc @nick||', 'nick'), isTrue);
  });

  test('an empty username never matches', () {
    expect(messageMentionsUsername('hey @nick', ''), isFalse);
  });

  test('a prefix that is not the whole username does not match', () {
    expect(messageMentionsUsername('hey @nick2', 'nick'), isFalse);
  });
}
