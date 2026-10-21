// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Authors are resolved in batches: a page of messages with forty unseen
/// authors costs one `GET /users?ids=`, not forty `GET /users/{id}` that the
/// AuthedRead bucket refuses halfway through.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/rate_limit_retry.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object> _profile(String id) => {
  'id': id,
  'username': id,
  'display_name': 'User $id',
  'created_at': 0,
};

class _Rig {
  _Rig(this.container, this.requests, this.waits);
  final ProviderContainer container;

  /// `METHOD path?query` of every request that reached the server.
  final List<Uri> requests;
  final List<Duration> waits;

  List<Uri> get batches => requests.where((u) => u.path == '/users').toList();
  List<Uri> get singles =>
      requests.where((u) => u.path.startsWith('/users/')).toList();
}

/// A container whose server knows every id except those in [gone], and
/// refuses the first [refusals] batch requests with a 429.
_Rig _rig({Set<String> gone = const {}, int refusals = 0, int? retryAfter}) {
  final requests = <Uri>[];
  final waits = <Duration>[];
  var refused = 0;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      rateLimitWaitProvider.overrideWithValue((d) async => waits.add(d)),
      mockApiOverride((request) async {
        requests.add(request.url);
        if (request.url.path != '/users') {
          return http.Response('{"error":"unexpected"}', 404);
        }
        if (refused < refusals) {
          refused++;
          return http.Response(
            jsonEncode({
              'error': 'rate limited',
              if (retryAfter != null) 'retry_after_seconds': retryAfter,
            }),
            429,
          );
        }
        final ids = request.url.queryParameters['ids']!.split(',');
        expect(ids.length, lessThanOrEqualTo(100));
        return http.Response(
          jsonEncode([
            for (final id in ids)
              if (!gone.contains(id)) _profile(id),
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  return _Rig(container, requests, waits);
}

void main() {
  test('forty authors asked for in one frame ride one request', () async {
    final rig = _rig();
    final ids = [for (var i = 0; i < 40; i++) 'author-$i'];

    final profiles = await Future.wait([
      for (final id in ids) rig.container.read(userProfileProvider(id).future),
    ]);

    expect(rig.batches, hasLength(1));
    expect(rig.singles, isEmpty, reason: 'no GET /users/{id} at all');
    expect(
      rig.batches.single.queryParameters['ids']!.split(','),
      unorderedEquals(ids),
    );
    expect(profiles.map((p) => p?.displayName), [
      for (final id in ids) 'User $id',
    ]);
  });

  test('an author already held is never asked for again', () async {
    final rig = _rig();
    await rig.container.read(userProfileProvider('a').future);
    expect(rig.requests, hasLength(1));

    // The family entry is autoDispose; the held profile is not.
    rig.container.invalidate(userProfileProvider('a'));
    final again = await rig.container.read(userProfileProvider('a').future);
    await rig.container.read(batchProfilesControllerProvider.notifier).resolve([
      'a',
    ]);

    expect(again?.displayName, 'User a');
    expect(rig.requests, hasLength(1));
  });

  test('an id asked for while its batch is in flight joins it', () async {
    final rig = _rig();
    final first = rig.container.read(userProfileProvider('a').future);
    await Future<void>.delayed(Duration.zero);
    final second = rig.container
        .read(batchProfilesControllerProvider.notifier)
        .profile('a');

    await Future.wait([first, second]);

    expect(rig.requests, hasLength(1));
  });

  test('an id the server no longer knows resolves to null, once', () async {
    final rig = _rig(gone: {'ghost'});

    final ghost = await rig.container.read(userProfileProvider('ghost').future);
    await rig.container.read(batchProfilesControllerProvider.notifier).resolve([
      'ghost',
    ]);

    expect(ghost, isNull);
    expect(rig.requests, hasLength(1), reason: 'a confirmed miss is held too');
  });

  test(
    'more ids than the server cap are split into requests of at most 100',
    () async {
      final rig = _rig();
      final ids = [for (var i = 0; i < 250; i++) 'm-$i'];

      await rig.container
          .read(batchProfilesControllerProvider.notifier)
          .resolve(ids);

      expect(rig.batches, hasLength(3));
      final sizes = rig.batches
          .map((u) => u.queryParameters['ids']!.split(',').length)
          .toList();
      expect(sizes..sort(), [50, 100, 100]);
      expect(rig.container.read(batchProfilesControllerProvider).length, 250);
    },
  );

  test(
    'a rate-limited batch waits the time the server named and succeeds',
    () async {
      final rig = _rig(refusals: 2, retryAfter: 2);

      final profile = await rig.container.read(userProfileProvider('a').future);

      expect(profile?.displayName, 'User a');
      expect(rig.waits, [
        const Duration(seconds: 2),
        const Duration(seconds: 2),
      ]);
      expect(rig.batches, hasLength(3));
    },
  );

  test(
    'a batch refused past the retry budget fails and is asked again later',
    () async {
      final rig = _rig(refusals: 99, retryAfter: 1);

      await expectLater(
        rig.container.read(userProfileProvider('a').future),
        throwsA(isA<RateLimitedException>()),
      );
      expect(rig.waits, hasLength(rateLimitRetries));
      expect(
        rig.container.read(batchProfilesControllerProvider),
        isEmpty,
        reason: 'a refusal is not read as "this account is gone"',
      );
    },
  );
}
