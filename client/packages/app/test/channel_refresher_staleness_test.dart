// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/channel_refresher.dart';
import 'package:slimm_data/data.dart'
    show CategoryStore, MessageStore, SlimmDatabase;

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

Map<String, Object> _c(String id, int n) => {
  'id': id,
  'name': id,
  'kind': 'text',
  'created_at': n,
};

void main() {
  test(
    'a refreshAfterChange called after the GET was issued still ends with new data',
    () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      var server = [_c('chan-1', 1)];
      final gate = Completer<void>();
      var channelGets = 0;
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path == '/channels') {
            channelGets++;
            final snapshot = [
              ...server,
            ]; // the server answers with state at request time
            if (channelGets == 1) await gate.future;
            return _json(snapshot);
          }
          if (path == '/categories' || path == '/dms') return _json(<Object>[]);
          if (path == '/read-states') return _json(<Object>[]);
          return http.Response('nf', 404);
        }),
      );
      final r = ChannelRefresher();
      final first = r.refreshAfterChange(api, store, isCurrent: () => true);
      await Future<void>.delayed(
        const Duration(milliseconds: 20),
      ); // GET issued, pre-change snapshot taken
      // a permission overwrite changes and reveals a new channel; event arrives
      server = [_c('chan-1', 1), _c('chan-2', 2)];
      final second = r.refreshAfterChange(api, store, isCurrent: () => true);
      gate.complete();
      await Future.wait([first, second]);

      expect(
        (await store.allChannels()).map((c) => c.id),
        containsAll(['chan-1', 'chan-2']),
        reason:
            'the event-triggered refresh joined a run that read pre-change data',
      );
    },
  );

  test('a refresh re-checks isCurrent before replaceCategories', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var current = true;
    final store = _SignOutDuringWrite(db, () => current = false);
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/channels') return _json([_c('chan-1', 1)]);
        if (path == '/categories') {
          return _json([
            {
              'id': 'cat-1',
              'name': 'old account',
              'position': 0,
              'created_at': 0,
            },
          ]);
        }
        if (path == '/dms' || path == '/read-states') return _json(<Object>[]);
        return http.Response('nf', 404);
      }),
    );
    await ChannelRefresher().refresh(api, store, isCurrent: () => current);
    expect(
      await store.allCategories(),
      isEmpty,
      reason:
          'isCurrent went false during replaceChannels, so categories must not be written',
    );
  });
}

class _SignOutDuringWrite extends MessageStore {
  _SignOutDuringWrite(super.db, this.onChannelsWritten);
  final void Function() onChannelsWritten;

  @override
  Future<void> replaceChannels(List<Channel> channels) async {
    await super.replaceChannels(channels);
    onChannelsWritten();
  }
}
