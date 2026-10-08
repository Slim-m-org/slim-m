// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Emoji in a poll: the composer can pick one into the question or an
/// option, and the poll view draws a custom shortcode as its image.
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
import 'package:slimm_app/src/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _grinningFace = '\u{1F600}';

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// With custom emoji the picker opens on them, so the sheet tests leave the list empty and land on the smileys.
Widget _app(Widget home, {bool custom = true}) => ProviderScope(
  overrides: [
    if (custom)
      customEmojiProvider.overrideWith(
        (ref) => [
          api.CustomEmoji(
            id: 'e-tada',
            name: 'tada',
            uploaderId: 'u1',
            createdAt: 1,
          ),
        ],
      ),
    customEmojiImageProvider.overrideWith((ref, id) => _png),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: home),
  ),
);

Finder _field(String placeholder) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == placeholder,
);

Finder _emojiButton(String label) => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == label,
);

String _typed(WidgetTester tester, String placeholder) =>
    tester.widget<AppInput>(_field(placeholder)).controller!.text;

void main() {
  testWidgets('a custom shortcode in the question and an option is an image', (
    tester,
  ) async {
    final poll = api.Poll(
      question: 'ship it :tada:',
      options: [
        api.PollOption(position: 0, label: 'yes :tada:', votes: 0),
        api.PollOption(position: 1, label: 'no', votes: 0),
      ],
      totalVotes: 0,
      votedOption: null,
      closeAt: null,
      closed: false,
    );
    await tester.pumpWidget(_app(PollView(poll: poll, onVote: (_) {})));
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNWidgets(2));
    expect(find.textContaining(':tada:'), findsNothing);
  });

  group('the composer sheet', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> openSheet(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPollComposerSheet(context, 'c-general'),
              child: const Text('open'),
            ),
          ),
          custom: false,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('picks an emoji into the question at the caret', (
      tester,
    ) async {
      await openSheet(tester);
      await tester.enterText(_field('Ask a question'), 'lunch ?');
      final controller = tester
          .widget<AppInput>(_field('Ask a question'))
          .controller!;
      controller.selection = const TextSelection.collapsed(offset: 6);

      await tester.tap(_emojiButton('Insert emoji in the question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_grinningFace));
      await tester.pumpAndSettle();

      expect(_typed(tester, 'Ask a question'), 'lunch $_grinningFace?');
    });

    testWidgets('picks an emoji into the option beside the tapped button', (
      tester,
    ) async {
      await openSheet(tester);

      await tester.tap(_emojiButton('Insert emoji in option 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_grinningFace));
      await tester.pumpAndSettle();

      expect(_typed(tester, 'Option 2'), _grinningFace);
      expect(_typed(tester, 'Option 1'), isEmpty);
    });
  });
}
