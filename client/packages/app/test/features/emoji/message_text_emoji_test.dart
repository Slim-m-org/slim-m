// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `:shortcode:` rendering in a message body.
///
/// Driven through the real API client over a [MockClient] rather than through
/// an overridden provider, so what is under test is the whole chain a message
/// row actually uses: `GET /emoji`, the name-to-id index, and the image fetch.
///
/// The miss case gets as much attention as the hit. A colon is ordinary
/// punctuation, so resolving one too eagerly would turn every "10:30:45" in
/// the deployment into a rendering bug.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A 1x1 transparent PNG. The bytes only have to be a real image; nothing
/// here asserts on pixels.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

Map<String, dynamic> _emojiJson(String id, String name) => {
  'id': id,
  'name': name,
  'uploader_id': null,
  'created_at': 0,
};

/// The deployment holds `tada`, `party_parrot` and `30`, and nothing else.
/// Every request path is appended to [log], so a test can count them.
///
/// `30` is there because the server's name charset permits a digits-only
/// name, which is the one case where a `:shortcode:` and a clock time are the
/// same characters. Without it every colon test below passes vacuously.
ProviderContainer _container([List<String>? log]) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            log?.add(request.url.path);
            if (request.url.path == '/emoji') {
              return http.Response(
                jsonEncode([
                  _emojiJson('e-tada', 'tada'),
                  _emojiJson('e-parrot', 'party_parrot'),
                  _emojiJson('e-thirty', '30'),
                ]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path.endsWith('/image')) {
              return http.Response.bytes(
                _png,
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            return http.Response('', 404);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Watches the index the way [ChannelScreen] does, so the test exercises the
/// provider rather than hand-feeding [MessageBody] a map.
class _Body extends ConsumerWidget {
  const _Body(this.content);

  final String content;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MessageBody(
    content: content,
    knownUsernames: const {},
    customEmoji: ref.watch(customEmojiIndexProvider),
  );
}

Future<void> _pump(WidgetTester tester, String content) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container(),
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: _Body(content)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a shortcode the deployment holds renders as its image', (
    tester,
  ) async {
    await _pump(tester, 'ship it :tada:');

    expect(find.byType(CustomEmojiImage), findsOneWidget);
    final emoji = tester.widget<CustomEmojiImage>(
      find.byType(CustomEmojiImage),
    );
    expect(emoji.emojiId, 'e-tada');

    expect(
      find.descendant(
        of: find.byType(CustomEmojiImage),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    // A picture no screen reader can describe has to say what it stands for.
    expect(
      find.descendant(
        of: find.byType(CustomEmojiImage),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == ':tada:',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an inline emoji is sized to the body line height, not to a '
      'pixel value of its own', (tester) async {
    await _pump(tester, ':tada:');

    final lineHeight = AppText.body.fontSize! * AppText.body.height!;
    final emoji = tester.widget<CustomEmojiImage>(
      find.byType(CustomEmojiImage),
    );
    expect(emoji.size, lineHeight);
    expect(
      tester.getSize(
        find
            .descendant(
              of: find.byType(CustomEmojiImage),
              matching: find.byType(SizedBox),
            )
            .first,
      ),
      Size(lineHeight, lineHeight),
    );
  });

  testWidgets('a shortcode the deployment does not hold stays literal text', (
    tester,
  ) async {
    await _pump(tester, 'we tried :not_an_emoji: today');

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.text('we tried :not_an_emoji: today'), findsOneWidget);
  });

  /// The deployment holds an emoji named `30`, so this is the case where the
  /// file's own claim that `10:30:45` survives untouched is worth something:
  /// without the digit-run rule it renders as 10, a picture, and 45.
  testWidgets('a clock time is a clock time even when the deployment holds an '
      'emoji named 30', (tester) async {
    await _pump(tester, 'standup at 10:30:45, agenda: the release');

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(
      find.text('standup at 10:30:45, agenda: the release'),
      findsOneWidget,
    );
  });

  /// The other half of that rule: refusing every digits-only name outright
  /// would leave an uploaded `:30:` in the picker and unrenderable anywhere.
  testWidgets('a digits-only emoji still renders where no digit touches the '
      'colons', (tester) async {
    await _pump(tester, 'we hit :30: today');

    expect(find.byType(CustomEmojiImage), findsOneWidget);
    expect(
      tester.widget<CustomEmojiImage>(find.byType(CustomEmojiImage)).emojiId,
      'e-thirty',
    );
  });

  testWidgets('a digits-only shortcode with a digit against either colon is '
      'left as text', (tester) async {
    await _pump(tester, 'at 9:30: and at :30:9');

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.text('at 9:30: and at :30:9'), findsOneWidget);
  });

  testWidgets('a shortcode inside an inline code span is code, not an emoji', (
    tester,
  ) async {
    await _pump(tester, 'type `:tada:` to send one');

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.byType(AppInlineCode), findsOneWidget);
    expect(find.text(':tada:'), findsOneWidget);
  });

  testWidgets('a shortcode inside a fenced block is code, not an emoji', (
    tester,
  ) async {
    await _pump(tester, 'like this:\n```\n:tada:\n```');

    expect(find.byType(CustomEmojiImage), findsNothing);
    expect(find.byType(AppCodeBlock), findsOneWidget);
  });

  testWidgets('two shortcodes in one message both resolve, independently', (
    tester,
  ) async {
    await _pump(tester, ':tada: shipped, :party_parrot: merged');

    final spans = tester
        .widgetList<CustomEmojiImage>(find.byType(CustomEmojiImage))
        .toList();
    expect(spans, hasLength(2));
    expect(spans.map((s) => s.emojiId), ['e-tada', 'e-parrot']);
  });

  testWidgets('a hit and a miss in one message resolve one and not the other', (
    tester,
  ) async {
    await _pump(tester, ':tada: at :nope: oclock');

    expect(find.byType(CustomEmojiImage), findsOneWidget);
    expect(find.textContaining(':nope:'), findsOneWidget);
  });

  testWidgets('ten rows share one emoji list and one image fetch between '
      'them, not one each', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container(log),
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 10; i++) const _Body('shipped :tada:'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNWidgets(10));
    expect(log.where((p) => p == '/emoji'), hasLength(1));
    expect(log.where((p) => p == '/emoji/e-tada/image'), hasLength(1));
  });
}
