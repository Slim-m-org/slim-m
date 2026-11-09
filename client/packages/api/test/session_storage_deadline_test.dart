// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A key store call that never returns costs one slow rotation, not every
/// request after it: the wait before a rotation is bounded like the wait after.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/session_store.dart' show storageDeadline;
import 'package:test/test.dart';

TokenPair _pair(int n) => TokenPair(
      userId: 'user-1',
      accessToken: 'access-$n',
      refreshToken: 'refresh-$n',
      accessExpiresAt: 0,
    );

class _Sync implements SessionSync {
  _Sync(this._read);

  final Future<TokenPair?> Function() _read;

  @override
  Future<T> exclusive<T>(Future<T> Function() body) => body();

  @override
  Future<TokenPair?> readStored() => _read();
}

Future<void> _hung(TokenPair? _) => Completer<void>().future;

final _beforeDeadline = storageDeadline - const Duration(seconds: 1);
const _pastDeadline = Duration(seconds: 2);

void main() {
  test('a hung write does not hold the pre-rotation read forever', () {
    fakeAsync((async) {
      final session = SessionStore(
        tokens: _pair(1),
        onChange: _hung,
        sync: _Sync(() async => _pair(1)),
      )..set(_pair(2));

      var done = false;
      TokenPair? adopted;
      session.adoptStoredRotation().then((value) {
        done = true;
        adopted = value;
      });

      async.elapse(_beforeDeadline);
      expect(done, isFalse);
      async.elapse(_pastDeadline);
      expect(done, isTrue);
      expect(adopted, isNull, reason: 'storage may be behind: rotate instead');
    });
  });

  test('a hung key store read does not hold the rotation forever', () {
    fakeAsync((async) {
      final session = SessionStore(
        tokens: _pair(1),
        sync: _Sync(() => Completer<TokenPair?>().future),
      );

      var done = false;
      TokenPair? adopted;
      session.adoptStoredRotation().then((value) {
        done = true;
        adopted = value;
      });

      async.elapse(_beforeDeadline);
      expect(done, isFalse);
      async.elapse(_pastDeadline);
      expect(done, isTrue);
      expect(adopted, isNull);
    });
  });

  test('a 401 still completes when the key store never answers', () {
    fakeAsync((async) {
      var refreshes = 0;
      final session = SessionStore(
        tokens: _pair(1),
        onChange: _hung,
        sync: _Sync(() => Completer<TokenPair?>().future),
      )..set(_pair(1));
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: session,
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshes++;
            return http.Response(jsonEncode(_pair(2).toJson()), 200);
          }
          final live = request.headers['authorization'] == 'Bearer access-2';
          return live ? http.Response('[]', 200) : http.Response('{}', 401);
        }),
      );

      var done = false;
      api.listChannels().then((_) => done = true);

      async.elapse(const Duration(seconds: 3));
      expect(done, isFalse);
      async.elapse(storageDeadline * 2 + const Duration(seconds: 2));
      expect(done, isTrue);
      expect(refreshes, 1);
    });
  });
}
