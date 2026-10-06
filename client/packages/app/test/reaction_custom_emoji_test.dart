// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for reacting with one of the deployment's own emoji.
///
/// A reaction is keyed on a string the server hands back verbatim, so the
/// deployment's own emoji travels as its `:shortcode:`. That only works if the
/// token the picker emits is one the chip can draw, so the second test here
/// takes the token out of the real picker rather than typing it again.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

/// A codepoint reaction, escaped rather than literal: the hygiene gate
/// forbids an emoji codepoint anywhere in `client/`.
const _tada = '\u{1F389}';

/// A 1x1 transparent PNG, so `Image.memory` decodes rather than throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

final _partyParrot = api.CustomEmoji(
  id: 'e-party_parrot',
  name: 'party_parrot',
  uploaderId: 'u1',
  createdAt: 1,
);

api.ReactionSummary _summary(String emoji, {bool reacted = false}) =>
    api.ReactionSummary(emoji: emoji, count: 3, reacted: reacted);

Widget _harness(Widget child, {List<api.CustomEmoji> custom = const []}) =>
    ProviderScope(
      overrides: [
        customEmojiProvider.overrideWith((ref) => custom),
        customEmojiImageProvider.overrideWith((ref, id) => _png),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

/// A whole [MessageRow], reading the index off the provider the way
/// `ChannelScreen` does. Not the bare `ReactionsRow`: the row forwarding that
/// index to its chips is half of what makes this work, and a test that built
/// the inner widget itself would pass with the forwarding deleted.
class _Row extends ConsumerWidget {
  const _Row(this.reactions, {this.onReactionTap});

  final List<api.ReactionSummary> reactions;
  final ValueChanged<api.ReactionSummary>? onReactionTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MessageRow(
    message: message(),
    grouped: false,
    showNewDivider: false,
    knownUsernames: const {},
    customEmoji: ref.watch(customEmojiIndexProvider),
    actions: noActions,
    editing: false,
    callbacks: MessageRowCallbacks(
      onRetry: () {},
      onDiscard: () {},
      onPickReaction: (_) {},
      onReactionTap: onReactionTap ?? (_) {},
      onVote: (_) {},
      onSubmitEdit: (_) {},
      onCancelEdit: () {},
    ),
    extras: MessageExtras(reactions: reactions),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a reaction keyed by a shortcode the deployment holds draws '
      'its image, not the shortcode text', (tester) async {
    await tester.pumpWidget(
      _harness(_Row([_summary(':party_parrot:')]), custom: [_partyParrot]),
    );
    await tester.pumpAndSettle();

    expect(find.text(':party_parrot:'), findsNothing);
    expect(find.byType(CustomEmojiImage), findsOneWidget);
    final image = tester.widget<CustomEmojiImage>(
      find.byType(CustomEmojiImage),
    );
    expect(image.emojiId, 'e-party_parrot');
    expect(
      find.descendant(
        of: find.byType(CustomEmojiImage),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    // The count is the chip's, not the picture's, so it stays text.
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('the token the picker emits for a deployment emoji is one the '
      'chip can draw', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _harness(
        EmojiPickerPanel(onSelect: (token) => picked = token, onClose: () {}),
        custom: [_partyParrot],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CustomEmojiImage).first);
    await tester.pump();
    expect(picked, isNotNull);

    await tester.pumpWidget(
      _harness(_Row([_summary(picked!)]), custom: [_partyParrot]),
    );
    await tester.pumpAndSettle();

    expect(find.text(picked!), findsNothing);
    expect(
      tester.widget<CustomEmojiImage>(find.byType(CustomEmojiImage)).emojiId,
      _partyParrot.id,
    );
  });

  testWidgets('a picture no screen reader can describe is still named by its '
      'shortcode', (tester) async {
    await tester.pumpWidget(
      _harness(
        _Row([_summary(':party_parrot:', reacted: true)]),
        custom: [_partyParrot],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(':party_parrot: reaction, 3, you reacted'),
      findsOneWidget,
    );
  });

  testWidgets('a codepoint reaction is unaffected: no image, the character '
      'itself', (tester) async {
    await tester.pumpWidget(
      _harness(_Row([_summary(_tada)]), custom: [_partyParrot]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.text(_tada), findsOneWidget);
  });

  testWidgets('a shortcode the deployment no longer holds stays literal text, '
      'and is still tappable so it can be taken back', (tester) async {
    api.ReactionSummary? tapped;
    await tester.pumpWidget(
      _harness(
        _Row([
          _summary(':deleted_one:', reacted: true),
        ], onReactionTap: (r) => tapped = r),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.text(':deleted_one:'), findsOneWidget);

    await tester.tap(find.text(':deleted_one:'));
    await tester.pump();
    expect(tapped?.emoji, ':deleted_one:');
  });

  testWidgets('an ordinary colon-bearing reaction key is not mistaken for a '
      'shortcode', (tester) async {
    await tester.pumpWidget(
      _harness(_Row([_summary('10:30')]), custom: [_partyParrot]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.text('10:30'), findsOneWidget);
  });
}
