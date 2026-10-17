// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `mentionedBotUsernames`: which `@mentions` in composer text name a bot.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_bot_mentions.dart';

void main() {
  test('finds a mentioned bot among plain text', () {
    expect(mentionedBotUsernames('hey @helper can you do this', ['helper']), {
      'helper',
    });
  });

  test('matches case-insensitively but keeps the registered casing', () {
    expect(mentionedBotUsernames('@Helper', ['helper']), {'helper'});
  });

  test('a mention of a non-bot username is not returned', () {
    expect(mentionedBotUsernames('@priya are you around', ['helper']), isEmpty);
  });

  test('the same bot mentioned twice is returned once', () {
    expect(mentionedBotUsernames('@helper ping @helper again', ['helper']), {
      'helper',
    });
  });

  test('no mention at all returns empty', () {
    expect(mentionedBotUsernames('no mentions here', ['helper']), isEmpty);
  });
}
