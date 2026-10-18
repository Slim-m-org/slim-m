// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for drawing one of the deployment's own emoji, and for the lifetime
/// of the two providers behind it.
///
/// Both halves guard a decision that is invisible on screen when it is wrong.
/// A failed image fetch that renders nothing looks exactly like one still in
/// flight, and an `autoDispose` emoji provider looks exactly like a live one
/// until you count the fetches a scrolling transcript makes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

/// A 1x1 transparent PNG, so `Image.memory` decodes rather than throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

const _partyParrot = api.CustomEmoji(
  id: 'e-party_parrot',
  name: 'party_parrot',
  uploaderId: 'u1',
  createdAt: 1,
);

Widget _app(List<Override> overrides, Widget child) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

/// Watches the index the way a message row does, so unmounting this is
/// unmounting the last listener the index has.
class _IndexWatcher extends ConsumerWidget {
  const _IndexWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text('${ref.watch(customEmojiIndexProvider).length}');
}

void main() {
  group('a fetch that failed', () {
    testWidgets('shows the missing-image glyph rather than blank space, which '
        'is indistinguishable from one still loading', (tester) async {
      await tester.pumpWidget(
        _app([
          customEmojiImageProvider.overrideWith(
            (ref, id) => Future<Uint8List>.error(StateError('gone')),
          ),
        ], const CustomEmojiImage(emojiId: 'e-party_parrot')),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.imageMissing), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('is told apart from one still in flight, which draws nothing '
        'and holds the space', (tester) async {
      final pending = Completer<Uint8List>();
      await tester.pumpWidget(
        _app([
          customEmojiImageProvider.overrideWith((ref, id) => pending.future),
        ], const CustomEmojiImage(emojiId: 'e-party_parrot')),
      );
      await tester.pump();

      expect(find.byIcon(AppIcons.imageMissing), findsNothing);
      expect(find.byType(Image), findsNothing);

      pending.complete(_png);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('decode cap', () {
    testWidgets('never decodes past the tile size it is drawn at', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app([
          customEmojiImageProvider.overrideWith((ref, id) async => _png),
        ], const CustomEmojiImage(emojiId: 'e-party_parrot', size: 24)),
      );
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      final resized = image.image as ResizeImage;
      // 24dp at 2x, or a custom emoji upload decodes at its own full size.
      expect(resized.width, 48);
      expect(resized.height, 48);
    });
  });

  group('provider lifetime', () {
    testWidgets('the emoji index outlives the last widget watching it, so a '
        'transcript scrolling a row out does not refetch the set', (
      tester,
    ) async {
      var fetches = 0;
      final overrides = [
        customEmojiProvider.overrideWith((ref) async {
          fetches++;
          return [_partyParrot];
        }),
      ];

      await tester.pumpWidget(_app(overrides, const _IndexWatcher()));
      await tester.pumpAndSettle();
      expect(fetches, 1);

      await tester.pumpWidget(_app(overrides, const SizedBox.shrink()));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_app(overrides, const _IndexWatcher()));
      await tester.pumpAndSettle();

      expect(
        fetches,
        1,
        reason:
            'customEmojiIndexProvider must not be autoDispose: it is what '
            'holds the (autoDispose) list alive for the session',
      );
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('one emoji\'s bytes outlive the row that drew them, so the '
        'same emoji further down refetches nothing', (tester) async {
      var fetches = 0;
      final overrides = [
        customEmojiImageProvider.overrideWith((ref, id) async {
          fetches++;
          return _png;
        }),
      ];

      await tester.pumpWidget(
        _app(overrides, const CustomEmojiImage(emojiId: 'e-party_parrot')),
      );
      await tester.pumpAndSettle();
      expect(fetches, 1);

      await tester.pumpWidget(_app(overrides, const SizedBox.shrink()));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _app(overrides, const CustomEmojiImage(emojiId: 'e-party_parrot')),
      );
      await tester.pumpAndSettle();

      expect(
        fetches,
        1,
        reason:
            'customEmojiImageProvider must not be autoDispose: the same '
            'emoji recurs down a transcript',
      );
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('a rate-limited fetch', () {
    testWidgets(
      'retries and still draws the image, rather than caching one 429 as a '
      'permanently broken emoji - the shape a large bulk import hits when '
      'every settings-list row fetches its image at once past the asset '
      'budget',
      (tester) async {
        var requests = 0;
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWithValue(
              api.SessionStore(
                tokens: const api.TokenPair(
                  userId: 'u1',
                  accessToken: 'a',
                  refreshToken: 'r',
                  accessExpiresAt: 9999999999999,
                ),
              ),
            ),
            mockApiOverride((request) async {
              requests += 1;
              if (requests <= 2) {
                return http.Response('{"error":"slow down and retry"}', 429);
              }
              return http.Response.bytes(
                _png,
                200,
                headers: {'content-type': 'image/png'},
              );
            }),
          ],
        );
        addTearDown(container.dispose);

        // runAsync escapes the virtual clock so the retry's real delay fires.
        final bytes = await tester.runAsync(
          () =>
              container.read(customEmojiImageProvider('e-party_parrot').future),
        );

        expect(bytes, _png);
        expect(
          requests,
          3,
          reason: 'the first two 429s must be retried, not surfaced',
        );
      },
    );

    testWidgets(
      'gives up and shows the missing-image glyph once retries are spent, '
      'rather than retrying forever',
      (tester) async {
        var requests = 0;
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWithValue(
              api.SessionStore(
                tokens: const api.TokenPair(
                  userId: 'u1',
                  accessToken: 'a',
                  refreshToken: 'r',
                  accessExpiresAt: 9999999999999,
                ),
              ),
            ),
            mockApiOverride((request) async {
              requests += 1;
              return http.Response('{"error":"slow down"}', 429);
            }),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await expectLater(
            container.read(customEmojiImageProvider('e-party_parrot').future),
            throwsA(isA<api.RateLimitedException>()),
          );
        });
        expect(requests, 4, reason: 'one try plus three retries, then give up');
      },
    );
  });
}
