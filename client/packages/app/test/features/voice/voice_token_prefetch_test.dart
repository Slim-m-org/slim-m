// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_token_prefetch.dart';

void main() {
  late DateTime now;
  late List<String> fetched;
  late Object? failure;
  late VoiceTokenPrefetch prefetch;

  VoiceToken token(String channelId, int n) => VoiceToken(
    url: 'wss://sfu.example.com',
    room: channelId,
    token: 'jwt-$n',
    expiresAt: 0,
    canPublish: true,
  );

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    fetched = [];
    failure = null;
    prefetch = VoiceTokenPrefetch((channelId) async {
      fetched.add(channelId);
      final error = failure;
      if (error != null) throw error;
      return token(channelId, fetched.length);
    }, now: () => now);
  });

  test('a join inside the hold takes the prefetched token', () async {
    prefetch.prefetch('a');
    now = now.add(const Duration(seconds: 29));

    final claimed = await prefetch.claim('a');

    expect(claimed.token, 'jwt-1');
    expect(fetched, ['a']);
  });

  test('a token past the hold is not handed out', () async {
    prefetch.prefetch('a');
    now = now.add(const Duration(seconds: 31));

    final claimed = await prefetch.claim('a');

    expect(claimed.token, 'jwt-2');
    expect(fetched, ['a', 'a']);
  });

  test('a token is handed out once', () async {
    prefetch.prefetch('a');
    await prefetch.claim('a');
    final second = await prefetch.claim('a');

    expect(second.token, 'jwt-2');
  });

  test('prefetching again inside the hold asks the server once', () async {
    prefetch.prefetch('a');
    prefetch.prefetch('a');
    now = now.add(const Duration(seconds: 10));
    prefetch.prefetch('a');

    expect(fetched, ['a']);
  });

  test('prefetching after the hold mints a fresh token', () async {
    prefetch.prefetch('a');
    now = now.add(const Duration(seconds: 31));
    prefetch.prefetch('a');

    expect(fetched, ['a', 'a']);
  });

  test(
    'a refusal is not asked again inside the hold, and the join sees it',
    () async {
      failure = const ForbiddenException('no');
      prefetch.prefetch('a');
      await pumpEventQueue();
      prefetch.prefetch('a');
      expect(fetched, ['a']);

      await expectLater(
        prefetch.claim('a'),
        throwsA(isA<ForbiddenException>()),
      );
      expect(fetched, ['a', 'a']);
    },
  );

  test('only the three newest channels are kept', () async {
    for (final id in ['a', 'b', 'c', 'd']) {
      prefetch.prefetch(id);
    }
    fetched.clear();

    await prefetch.claim('d');
    expect(fetched, isEmpty);

    await prefetch.claim('a');
    expect(fetched, ['a']);
  });
}
