// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An emoji names itself: hovering one in message text shows its `:name:`, a
/// long press on the glyph does the same on a phone, a custom emoji carries
/// its shortcode as a tooltip, and a reaction's tooltip starts with the name.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_name_tip.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_names.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_api.dart';

const _grinning = '\u{1F600}';
const _thumb = '\u{1F44D}';

Widget _app(Widget child) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(
      api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'self',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
    ),
    mockApiOverride((_) async => http.Response('[]', 200)),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: GestureDetector(
        onLongPress: () => _rowLongPresses++,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  ),
);

int _rowLongPresses = 0;

/// Where character [offset] of the message's paragraph sits on screen.
Offset _glyphAt(WidgetTester tester, int offset) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.byType(RichText).first,
  );
  final caret = paragraph.getOffsetForCaret(
    TextPosition(offset: offset),
    Rect.zero,
  );
  return paragraph.localToGlobal(caret + const Offset(6, 8));
}

Finder get _tip => find.byKey(EmojiNameTip.labelKey);

void main() {
  setUp(() => _rowLongPresses = 0);

  test('glyphs resolve to the picker catalog names', () {
    expect(standardEmojiShortcode(_grinning), ':grinning:');
    expect(standardEmojiShortcode('$_thumb\u{1F3FD}'), isNotNull);
    expect(standardEmojiShortcode('$_thumb\u{1F3FD}'), ':thumbsup_tone3:');
    expect(standardEmojiShortcode('a'), isNull);
    expect(emojiDisplayName(':party:', const {'party': 'e1'}), ':party:');
    expect(emojiDisplayName(':nope:', const {'party': 'e1'}), isNull);
  });

  testWidgets('hovering an emoji in message text shows its name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const MessageBody(content: 'hi $_grinning', knownUsernames: {})),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    await mouse.moveTo(_glyphAt(tester, 3));
    await tester.pump(emojiNameHoverRest + const Duration(milliseconds: 50));
    expect(_tip, findsOneWidget);
    expect(find.text(':grinning:'), findsOneWidget);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(_tip, findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('hovering plain text shows nothing', (tester) async {
    await tester.pumpWidget(
      _app(const MessageBody(content: 'hi $_grinning', knownUsernames: {})),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    await mouse.moveTo(_glyphAt(tester, 0));
    await tester.pump(emojiNameHoverRest + const Duration(milliseconds: 50));
    expect(_tip, findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('on a phone, a long press on the glyph names it, elsewhere '
      'the row still gets the long press', (tester) async {
    await tester.pumpWidget(
      _app(const MessageBody(content: 'hi $_grinning', knownUsernames: {})),
    );

    await tester.longPressAt(_glyphAt(tester, 3));
    await tester.pump();
    expect(find.text(':grinning:'), findsOneWidget);
    expect(_rowLongPresses, 0);
    await tester.pump(emojiNameLinger + const Duration(milliseconds: 50));
    expect(_tip, findsNothing);

    await tester.longPressAt(_glyphAt(tester, 0));
    await tester.pump();
    expect(_tip, findsNothing);
    expect(_rowLongPresses, 1);
  });

  testWidgets('a custom emoji carries its shortcode as a tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const MessageBody(
          content: 'nice :party:',
          knownUsernames: {},
          customEmoji: {'party': 'e1'},
        ),
      ),
    );
    expect(find.byTooltip(':party:'), findsOneWidget);
  });

  testWidgets('a reaction tooltip starts with the emoji name', (tester) async {
    await tester.pumpWidget(
      _app(
        ReactionsRow(
          messageId: 'm1',
          reactions: const [
            api.ReactionSummary(emoji: _thumb, count: 3, reacted: false),
          ],
          onReactionTap: (_) {},
        ),
      ),
    );
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip).first);
    expect(tooltip.message, startsWith('${standardEmojiShortcode(_thumb)}\n'));
  });
}
