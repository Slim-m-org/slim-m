// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [messageMentionsUsername].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_mentions.dart';

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

  group('messageMentionsMe', () {
    bool mentions(String content, {List<String> roles = const []}) =>
        messageMentionsMe(content, username: 'nick', roleNames: roles);

    test('counts the account\'s own username', () {
      expect(mentions('hey @nick'), isTrue);
    });

    test('counts @everyone and @here, in any case', () {
      expect(mentions('@everyone standup'), isTrue);
      expect(mentions('quick q @here'), isTrue);
      expect(mentions('@Everyone'), isTrue);
    });

    test('counts a role the account holds, by name and in any case', () {
      expect(mentions('ping @[Core Team]', roles: ['Core Team']), isTrue);
      expect(mentions('ping @[core team]', roles: ['Core Team']), isTrue);
    });

    test('ignores a role the account does not hold', () {
      expect(mentions('ping @[Core Team]', roles: ['Designers']), isFalse);
      expect(mentions('ping @[Core Team]'), isFalse);
    });

    test(
      'ignores someone else\'s name and a name that only starts the same',
      () {
        expect(mentions('hey @alice'), isFalse);
        expect(mentions('hey @everyoneelse'), isFalse);
      },
    );

    test('finds a broadcast inside formatting and a spoiler', () {
      expect(mentions('**@everyone**'), isTrue);
      expect(mentions('||@here||'), isTrue);
    });

    test('does not read code, inline or fenced', () {
      expect(mentions('`@everyone`'), isFalse);
      expect(mentions('```\n@here\n```'), isFalse);
    });

    test('messageMentionsUsername still means only that username', () {
      expect(messageMentionsUsername('@everyone', 'nick'), isFalse);
    });
  });
}
