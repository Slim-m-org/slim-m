// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ChannelRefresher` refreshes the channel and DM listings, hydrates each
/// channel's read marker, and dedups a concurrent refresh into the one already
/// running. None of that was tested: `sync_controller_race_test` drives the
/// whole `SyncController` and only trips the outer `isCurrent` checkpoint for
/// one sign-out race, never the dedup, the discard, the legacy per-channel
/// error isolation, or the second checkpoint inside the read-marker loop.
///
/// The request-count tests pin the sign-in cost: the markers of every channel
/// arrive in one `GET /read-states`, however many channels there are.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/channel_refresher.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

const _twoChannels = [
  {'id': 'chan-1', 'name': 'general', 'kind': 'text', 'created_at': 1},
  {'id': 'chan-2', 'name': 'random', 'kind': 'text', 'created_at': 2},
];

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A refresher fixture: the store to inspect afterwards, the api to drive, and
/// a per-path request tally so a dedup can be proven as one round trip.
class _Fixture {
  _Fixture(this.db, this.store, this.api, this.hits);
  final SlimmDatabase db;
  final MessageStore store;
  final SlimmApi api;
  final Map<String, int> hits;
}

/// Builds an api whose `/channels` returns [channels] and whose
/// `/read-states` reports [readSeq] for each. With [legacyServer] that route
/// answers 404 like a server that predates it, and the per-channel `/read`
/// answers instead, 500 for any id in [failingReads]. [readStatesStatus]
/// replaces the batch route's answer outright. Every request is tallied by
/// path.
_Fixture _fixture({
  List<Map<String, Object>> channels = _twoChannels,
  Set<String> failingReads = const {},
  int readSeq = 5,
  bool legacyServer = false,
  int readStatesStatus = 200,
}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  final hits = <String, int>{};
  final api = SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: SessionStore(tokens: _tokens),
    httpClient: MockClient((request) async {
      final path = request.url.path;
      hits[path] = (hits[path] ?? 0) + 1;
      if (path == '/channels') return _json(channels);
      if (path == '/categories') return _json(<Object>[]);
      if (path == '/dms') return _json(<Object>[]);
      if (path == '/read-states') {
        if (legacyServer) return http.Response('not found', 404);
        if (readStatesStatus != 200) {
          return http.Response(
            '{"error":"nope"}',
            readStatesStatus,
            headers: {'content-type': 'application/json'},
          );
        }
        return _json([
          for (final c in channels)
            {
              'channel_id': c['id'],
              'last_read_seq': readSeq,
              'unread': 0,
              'manually_unread': false,
            },
        ]);
      }
      if (path.endsWith('/read')) {
        final id = path.split('/')[2];
        if (failingReads.contains(id)) {
          return http.Response(
            '{"error":"nope"}',
            500,
            headers: {'content-type': 'application/json'},
          );
        }
        return _json({'last_read_seq': readSeq, 'unread': 0});
      }
      return http.Response('not found', 404);
    }),
  );
  return _Fixture(db, store, api, hits);
}

Future<int?> _marker(MessageStore store, String id) async {
  final channels = await store.allChannels();
  return channels
      .where((c) => c.id == id)
      .map((c) => c.lastReadSeq)
      .firstOrNull;
}

void main() {
  test('two concurrent refreshes collapse into one round trip', () async {
    final f = _fixture();
    addTearDown(f.db.close);
    final refresher = ChannelRefresher();

    final a = refresher.refreshOnce(f.api, f.store, isCurrent: () => true);
    final b = refresher.refreshOnce(f.api, f.store, isCurrent: () => true);
    await Future.wait([a, b]);

    expect(identical(a, b), isTrue, reason: 'the second joins the first');
    expect(
      f.hits['/channels'],
      1,
      reason: 'not one listing fetched per caller',
    );
  });

  test('a burst of change-driven refreshes costs one running and one '
      'trailing round trip', () async {
    final f = _fixture();
    addTearDown(f.db.close);
    final refresher = ChannelRefresher();

    final a = refresher.refreshAfterChange(
      f.api,
      f.store,
      isCurrent: () => true,
    );
    final b = refresher.refreshAfterChange(
      f.api,
      f.store,
      isCurrent: () => true,
    );
    final c = refresher.refreshAfterChange(
      f.api,
      f.store,
      isCurrent: () => true,
    );
    await Future.wait([a, b, c]);

    expect(identical(b, c), isTrue, reason: 'late callers share one rerun');
    expect(f.hits['/channels'], 2);
  });

  test('discardInFlight lets the next caller start a fresh refresh', () async {
    final f = _fixture();
    addTearDown(f.db.close);
    final refresher = ChannelRefresher();

    final a = refresher.refreshOnce(f.api, f.store, isCurrent: () => true);
    // A new session: the later caller must not inherit the old guard's future.
    refresher.discardInFlight();
    final b = refresher.refreshOnce(f.api, f.store, isCurrent: () => true);
    await Future.wait([a, b]);

    expect(identical(a, b), isFalse);
    expect(f.hits['/channels'], 2, reason: 'each session refreshed for itself');
  });

  test('one channel failing its read state does not stop the others on a '
      'server without GET /read-states', () async {
    final f = _fixture(
      failingReads: {'chan-1'},
      readSeq: 7,
      legacyServer: true,
    );
    addTearDown(f.db.close);

    await ChannelRefresher().refresh(f.api, f.store, isCurrent: () => true);

    expect(
      await _marker(f.store, 'chan-2'),
      7,
      reason: 'its marker still lands',
    );
    expect(
      await _marker(f.store, 'chan-1'),
      0,
      reason: 'the failed read is best-effort, left for the next refresh',
    );
  });

  test(
    'every channel marker arrives in one request, not one per channel',
    () async {
      final sixty = [
        for (var i = 0; i < 60; i++)
          {'id': 'chan-$i', 'name': 'c$i', 'kind': 'text', 'created_at': i},
      ];
      final f = _fixture(channels: sixty, readSeq: 4);
      addTearDown(f.db.close);

      await ChannelRefresher().refresh(f.api, f.store, isCurrent: () => true);

      expect(f.hits['/read-states'], 1);
      expect(
        f.hits.keys.where((p) => p.endsWith('/read')),
        isEmpty,
        reason: 'no per-channel read request is made',
      );
      expect(await _marker(f.store, 'chan-0'), 4);
      expect(await _marker(f.store, 'chan-59'), 4);
    },
  );

  test(
    'a failed batch leaves the channels written and the markers unset',
    () async {
      final f = _fixture(readStatesStatus: 500);
      addTearDown(f.db.close);

      await ChannelRefresher().refresh(f.api, f.store, isCurrent: () => true);

      expect(
        (await f.store.allChannels()).map((c) => c.id),
        containsAll(['chan-1', 'chan-2']),
      );
      expect(await _marker(f.store, 'chan-1'), 0);
      expect(f.hits['/read-states'], 1, reason: 'a 500 is not retried');
    },
  );

  test(
    'a rate-limited batch is retried after the wait the server named',
    () async {
      final waits = <Duration>[];
      var answers = 0;
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path == '/channels') return _json(_twoChannels);
          if (path == '/categories' || path == '/dms') return _json(<Object>[]);
          if (path == '/read-states') {
            if (answers++ < 2) {
              return http.Response(
                '{"error":"rate limited","retry_after_seconds":2}',
                429,
                headers: {'content-type': 'application/json'},
              );
            }
            return _json([
              {
                'channel_id': 'chan-1',
                'last_read_seq': 3,
                'unread': 0,
                'manually_unread': false,
              },
            ]);
          }
          return http.Response('not found', 404);
        }),
      );

      await ChannelRefresher().refresh(
        api,
        store,
        isCurrent: () => true,
        wait: (d) async => waits.add(d),
      );

      expect(waits, [const Duration(seconds: 2), const Duration(seconds: 2)]);
      expect(await _marker(store, 'chan-1'), 3);
    },
  );

  test(
    'isCurrent false on entry writes nothing the sign-out cleared',
    () async {
      final f = _fixture();
      addTearDown(f.db.close);

      await ChannelRefresher().refresh(f.api, f.store, isCurrent: () => false);

      expect(
        await f.store.allChannels(),
        isEmpty,
        reason: 'no channels written',
      );
      expect(
        f.hits.keys.any((p) => p.endsWith('/read') || p == '/read-states'),
        isFalse,
        reason: 'it returns before the read-marker loop, so no read is fetched',
      );
    },
  );

  test(
    'isCurrent flipping false mid-loop stops the read-marker writes',
    () async {
      final f = _fixture(readSeq: 9);
      addTearDown(f.db.close);

      // True for the entry check, false for every per-channel check after it.
      var checks = 0;
      await ChannelRefresher().refresh(
        f.api,
        f.store,
        isCurrent: () => (checks++) == 0,
      );

      expect(
        (await f.store.allChannels()).map((c) => c.id),
        containsAll(['chan-1', 'chan-2']),
        reason: 'the entry check passed, so the listing was written',
      );
      expect(await _marker(f.store, 'chan-1'), 0);
      expect(await _marker(f.store, 'chan-2'), 0);
    },
  );
}
