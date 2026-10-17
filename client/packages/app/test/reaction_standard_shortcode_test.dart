// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A standard emoji stored as `:shortcode:` draws as its codepoint.
///
/// An API caller or bot can react with `:anger:`; the server keeps it verbatim.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_app/src/features/emoji/widgets/standard_emoji.dart';
import 'package:slimm_design_system/design_system.dart';

const _anger = '\u{1F4A2}';

Widget _row(
  String emoji, {
  Map<String, String> custom = const {},
  ValueChanged<api.ReactionSummary>? onTap,
}) => ProviderScope(
  overrides: [
    customEmojiImageProvider.overrideWith(
      (ref, id) => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: ReactionsRow(
        reactions: [
          api.ReactionSummary(emoji: emoji, count: 1, reacted: false),
        ],
        onReactionTap: onTap ?? (_) {},
        customEmoji: custom,
      ),
    ),
  ),
);

void main() {
  test(
    'standardEmojiFor resolves a standard shortcode, case-insensitively',
    () {
      expect(standardEmojiFor(':anger:'), _anger);
      expect(standardEmojiFor(':ANGER:'), _anger);
    },
  );

  test(
    'standardEmojiFor ignores anything that is not a standard shortcode',
    () {
      expect(standardEmojiFor(_anger), isNull);
      expect(standardEmojiFor(':party_parrot:'), isNull);
      expect(standardEmojiFor('anger'), isNull);
      expect(standardEmojiFor('::'), isNull);
    },
  );

  testWidgets('a :anger: reaction draws the codepoint, not the text', (
    tester,
  ) async {
    await tester.pumpWidget(_row(':anger:'));

    expect(find.text(':anger:'), findsNothing);
    expect(find.text(_anger), findsOneWidget);
  });

  testWidgets('tapping it still reports the stored key so it can be undone', (
    tester,
  ) async {
    api.ReactionSummary? tapped;
    await tester.pumpWidget(_row(':anger:', onTap: (r) => tapped = r));

    await tester.tap(find.text(_anger));
    expect(tapped?.emoji, ':anger:');
  });

  testWidgets('a deployment emoji of the same name keeps the shortcode text', (
    tester,
  ) async {
    await tester.pumpWidget(_row(':anger:', custom: {'anger': 'e-anger'}));

    expect(find.text(_anger), findsNothing);
  });
}
