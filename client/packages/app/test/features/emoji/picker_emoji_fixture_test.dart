// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's emoji and the fixture the server tests its reaction rule
/// against (`crates/slimm-server/tests/fixtures/picker_emoji.json`) are the
/// same set, so the server can never refuse a reaction the app offers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:emojis/emoji.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shared fixture lists exactly what the picker offers', () {
    var repoRoot = Directory.current;
    while (!File('${repoRoot.path}/schema/openapi.yaml').existsSync()) {
      repoRoot = repoRoot.parent;
    }
    final fixture =
        jsonDecode(
              File(
                '${repoRoot.path}/crates/slimm-server/tests/fixtures/picker_emoji.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final offered = Emoji.all().where(
      (emoji) => emoji.emojiGroup != EmojiGroup.component,
    );

    expect((fixture['chars'] as List).cast<String>().toSet(), {
      for (final emoji in offered) emoji.char,
    }, reason: 'regenerate the fixture when the emojis package changes');
    expect((fixture['names'] as List).cast<String>().toSet(), {
      for (final emoji in offered) emoji.shortName,
    });
  });
}
