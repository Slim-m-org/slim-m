// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel the server stops listing is reported as lost, so a screen still
/// showing it can leave saying access was taken away.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/channel_refresher.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, Object> _c(String id, {String kind = 'text'}) => {
  'id': id,
  'name': id,
  'kind': kind,
  'created_at': 0,
};

void main() {
  test('a refresh reports the channels it dropped, with their names', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    var listed = [_c('general'), _c('secret')];
    final api = testApi((request) async {
      final path = request.url.path;
      if (path == '/channels') return _json(listed);
      if (path == '/categories' || path == '/dms') return _json(<Object>[]);
      if (path == '/read-states') return _json(<Object>[]);
      return http.Response('nf', 404);
    }, session: SessionStore(tokens: _tokens));
    final reported = <Map<String, String>>[];
    final refresher = ChannelRefresher(onLost: reported.add);

    await refresher.refresh(api, store, isCurrent: () => true);
    expect(reported, isEmpty, reason: 'nothing was held before');

    listed = [_c('general')];
    await refresher.refresh(api, store, isCurrent: () => true);
    expect(reported, [
      {'secret': 'secret'},
    ]);
  });

  test('a channel created while a refresh is in flight is not lost', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    final answer = Completer<void>();
    final api = testApi((request) async {
      final path = request.url.path;
      if (path == '/channels') {
        await answer.future;
        return _json([_c('general')]);
      }
      if (path == '/categories' || path == '/dms') return _json(<Object>[]);
      if (path == '/read-states') return _json(<Object>[]);
      return http.Response('nf', 404);
    }, session: SessionStore(tokens: _tokens));
    await store.upsertChannels([
      const Channel(id: 'general', name: 'general', kind: 'text', createdAt: 0),
    ]);
    final reported = <Map<String, String>>[];

    final refresh = ChannelRefresher(
      onLost: reported.add,
    ).refresh(api, store, isCurrent: () => true);
    await pumpEventQueue();
    await store.upsertChannels([
      const Channel(id: 'new', name: 'new-channel', kind: 'text', createdAt: 1),
    ]);
    answer.complete();
    await refresh;

    expect(reported, isEmpty);
    expect(
      [for (final c in await store.allChannels()) c.id],
      containsAll(['general', 'new']),
      reason: 'the listing was asked for before the channel existed',
    );
  });

  test('threads, DMs and rooms are not access losses', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const Channel(id: 'dm', name: 'bob', kind: 'dm', createdAt: 0),
      const Channel(id: 'gone', name: 'gone', kind: 'voice', createdAt: 0),
    ]);
    final held = await store.allChannels();

    expect(lostChannels(held, {'other'}), {'gone': 'gone'});
    expect(lostChannels(held, {'dm', 'gone'}), isEmpty);
  });
}
