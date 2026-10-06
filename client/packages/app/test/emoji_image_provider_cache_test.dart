// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the parts of `customEmojiImageProvider` that sit around the
/// network fetch itself: the disk cache short-circuiting it entirely, a
/// `Retry-After` header overriding the fixed backoff, and a rate limit that
/// outlasts every retry healing on its own rather than staying broken for
/// the rest of the session.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/emoji_image_cache.dart';
import 'package:slimm_app/src/providers/providers.dart';

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// An in-memory stand-in for [EmojiImageCache], so a test can both seed a
/// hit and observe what a fetch writes back, without a real filesystem.
class _FakeCache implements EmojiImageCache {
  final Map<String, Uint8List> store = {};

  @override
  Future<Uint8List?> read(String emojiId) async => store[emojiId];

  @override
  Future<void> write(String emojiId, Uint8List bytes) async {
    store[emojiId] = bytes;
  }
}

ProviderContainer _container({
  required EmojiImageCache cache,
  required http.Client httpClient,
}) {
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
      emojiImageCacheProvider.overrideWithValue(cache),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        ),
      ),
    ],
  );
  return container;
}

void main() {
  test('a cache hit resolves without ever calling the network', () async {
    final cache = _FakeCache()..store['e-1'] = _png;
    var requests = 0;
    final container = _container(
      cache: cache,
      httpClient: MockClient((request) async {
        requests++;
        return http.Response('should not be called', 500);
      }),
    );
    addTearDown(container.dispose);

    final bytes = await container.read(customEmojiImageProvider('e-1').future);

    expect(bytes, _png);
    expect(requests, 0);
  });

  test('a successful network fetch is written through to the cache', () async {
    final cache = _FakeCache();
    final container = _container(
      cache: cache,
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    addTearDown(container.dispose);

    await container.read(customEmojiImageProvider('e-1').future);

    expect(cache.store['e-1'], _png);
  });

  test('a 429 carrying Retry-After waits that long instead of the fixed '
      'backoff schedule', () async {
    var requests = 0;
    final container = _container(
      cache: _FakeCache(),
      httpClient: MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            '{"error":"slow down"}',
            429,
            headers: {'retry-after': '0'},
          );
        }
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );
    addTearDown(container.dispose);

    final stopwatch = Stopwatch()..start();
    await container.read(customEmojiImageProvider('e-1').future);
    stopwatch.stop();

    // The fixed schedule's first wait is 250ms; a header naming zero must land well under that.
    expect(stopwatch.elapsedMilliseconds, lessThan(150));
    expect(requests, 2);
  });

  test(
    'a rate limit that outlasts every retry heals on its own after the '
    'cooldown, rather than staying broken for the rest of the session',
    () async {
      final originalCooldown = emojiImageTombstoneCooldown;
      emojiImageTombstoneCooldown = const Duration(milliseconds: 30);
      addTearDown(() => emojiImageTombstoneCooldown = originalCooldown);

      var requests = 0;
      final container = _container(
        cache: _FakeCache(),
        httpClient: MockClient((request) async {
          requests++;
          if (requests <= 4) {
            return http.Response('{"error":"slow down"}', 429);
          }
          return http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(customEmojiImageProvider('e-1').future),
        throwsA(isA<api.RateLimitedException>()),
      );

      // Past the cooldown, the provider should retry on its own with no action from this test.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final bytes = await container.read(
        customEmojiImageProvider('e-1').future,
      );

      expect(bytes, _png);
    },
  );

  for (final mode in ['a 503', 'a dropped connection']) {
    test('$mode on the first fetch heals once it is over', () async {
      final originalCooldown = emojiImageTombstoneCooldown;
      emojiImageTombstoneCooldown = const Duration(milliseconds: 30);
      addTearDown(() => emojiImageTombstoneCooldown = originalCooldown);

      var requests = 0;
      final container = _container(
        cache: _FakeCache(),
        httpClient: MockClient((request) async {
          requests++;
          if (requests == 1) {
            if (mode == 'a 503') {
              return http.Response('{"error":"down"}', 503);
            }
            throw http.ClientException('connection reset');
          }
          return http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      addTearDown(container.dispose);
      final sub = container.listen(customEmojiImageProvider('e-1'), (_, _) {});
      addTearDown(sub.close);

      await expectLater(
        container.read(customEmojiImageProvider('e-1').future),
        throwsA(isA<api.ApiException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(container.read(customEmojiImageProvider('e-1')).valueOrNull, _png);
    });
  }

  for (final status in [403, 404]) {
    test('a $status is the answer and is not retried', () async {
      final originalCooldown = emojiImageTombstoneCooldown;
      emojiImageTombstoneCooldown = const Duration(milliseconds: 30);
      addTearDown(() => emojiImageTombstoneCooldown = originalCooldown);

      var requests = 0;
      final container = _container(
        cache: _FakeCache(),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{"error":"no"}', status);
        }),
      );
      addTearDown(container.dispose);
      final sub = container.listen(customEmojiImageProvider('e-1'), (_, _) {});
      addTearDown(sub.close);

      await expectLater(
        container.read(customEmojiImageProvider('e-1').future),
        throwsA(isA<api.ApiException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(requests, 1, reason: 'a refusal would only fail the same way');
    });
  }
}
