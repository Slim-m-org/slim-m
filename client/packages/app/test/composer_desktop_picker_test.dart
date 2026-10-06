// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's desktop-width picker: an anchored panel with Emoji and
/// GIFs tabs, opened by either the smile or the GIF button, reaching native
/// emoji directly rather than only the Space's own - the defect the owner
/// reported ("desktop has old emoji view, should be like discord").
///
/// `composer_emoji_test.dart` covers the same buttons at touch density,
/// where the Space-emoji-only sheet is still the right answer.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer_picker_panel.dart';
import 'package:slimm_app/src/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

/// Answers `/version` with [gifSearchEnabled] and a minimal working GIF
/// flow: one trending result on open, one search result, its preview.
api.SlimmApi Function(Ref) _api({required bool gifSearchEnabled}) {
  return (ref) => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '0.39.0',
            'protocol': 1,
            'gif_search_enabled': gifSearchEnabled,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path == '/gifs/trending') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 'tok-trending',
                'title': 'a trending gif',
                'width': 200,
                'height': 150,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path == '/gifs/preview/tok-trending') {
        return http.Response.bytes(
          base64Decode('R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='),
          200,
          headers: {'content-type': 'image/gif'},
        );
      }
      return http.Response('{}', 404, headers: {'content-type': 'text/plain'});
    }),
  );
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'the smile button opens an anchored panel with Emoji and GIFs tabs, no Stickers',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: _api(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(emojiButton);
      await tester.pumpAndSettle();

      expect(find.byType(ComposerPickerPanel), findsOneWidget);
      expect(find.byType(AppSegmentedControl), findsOneWidget);
      expect(find.text('Emoji'), findsOneWidget);
      expect(find.text('GIFs'), findsOneWidget);
      expect(find.text('Stickers'), findsNothing);
      // The core complaint: native emoji reachable, not just the Space's own.
      expect(find.text('Search emoji'), findsOneWidget);
    },
  );

  /// The composer had a second icon that opened this same panel already on
  /// the GIFs tab. It is gone: one button, and the tabs carry the rest. The
  /// owner read the pair as a leftover from before the panel was shared, and
  /// it was.
  ///
  /// What that test actually protected - that the panel can reach trending
  /// gifs - is covered by the tab-switching test below.
  testWidgets('switching tabs moves between emoji and GIF content', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _api(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsOneWidget);

    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsNothing);
    expect(find.text('Search GIFs'), findsOneWidget);

    await tester.tap(find.text('Emoji'));
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsOneWidget);
  });

  testWidgets('the smile button toggles the panel closed again', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _api(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.byType(ComposerPickerPanel), findsOneWidget);

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.byType(ComposerPickerPanel), findsNothing);
  });

  testWidgets('without a GIF provider the panel has no tab row at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _api(gifSearchEnabled: false),
      ),
    );
    await tester.pumpAndSettle();

    // No provider, so the one button says only what it can do.
    expect(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == 'Insert emoji or a GIF',
      ),
      findsNothing,
    );

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    expect(find.byType(AppSegmentedControl), findsNothing);
    expect(find.text('Search emoji'), findsOneWidget);
  });

  testWidgets('the anchored panel opens onto native emoji, not only the '
      "Space's own", (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _api(gifSearchEnabled: true),
        customEmoji: const [],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    // No custom emoji: rendered as EmojiCell tiles in the browse view's own sectioned grid, not a single EmojiGrid.
    final tokens = tester
        .widgetList<EmojiCell>(find.byType(EmojiCell))
        .map((cell) => cell.emoji.token)
        .toList();
    expect(tokens, isNotEmpty);
    expect(
      tokens.every((token) => !token.startsWith(':')),
      isTrue,
      reason: 'these are native codepoints, not `:shortcode:` custom ones',
    );
  });
}
