// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Transport and parsing edges: reaction paths, watch 404s, bad history rows,
/// and replay keys on creates.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _json = {'content-type': 'application/json'};

SlimmApi _api(http.Response Function(http.Request) answer) => SlimmApi(
      baseUrl: Uri.parse('https://chat.example'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'me',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 4102444800000,
        ),
      ),
      httpClient: MockClient((request) async => answer(request)),
    );

Map<String, dynamic> _message(String id) => {
      'id': id,
      'channel_id': 'c1',
      'author_id': 'u1',
      'seq': 1,
      'content': 'hi',
      'created_at': 0,
    };

void main() {
  group('a reaction emoji holding a slash', () {
    test('stays one path segment for add, list and remove', () async {
      final seen = <http.Request>[];
      final api = _api((request) {
        seen.add(request);
        return request.method == 'GET'
            ? http.Response(
                jsonEncode({'users': <Object>[], 'next_cursor': null}),
                200,
                headers: _json,
              )
            : http.Response('', 204);
      });

      await api.addReaction(messageId: 'm1', emoji: 'a/b');
      await api.listReactionUsers(messageId: 'm1', emoji: 'a/b');
      await api.removeReaction(messageId: 'm1', emoji: 'a/b');

      expect(seen.map((r) => r.method), ['PUT', 'GET', 'DELETE']);
      for (final request in seen) {
        expect(
            request.url.pathSegments, ['messages', 'm1', 'reactions', 'a/b']);
        expect(request.url.path, '/messages/m1/reactions/a%2Fb');
      }
    });

    test('a shortcode keeps its colons', () async {
      late Uri seen;
      final api = _api((request) {
        seen = request.url;
        return http.Response('', 204);
      });
      await api.addReaction(messageId: 'm1', emoji: ':party_cat:');
      expect(seen.pathSegments.last, ':party_cat:');
    });
  });

  group('getWatchSession', () {
    test('an unexplained 404 is rethrown, not read as nothing playing',
        () async {
      final api = _api((_) => http.Response('', 404));
      await expectLater(
        api.getWatchSession('c1'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('an explained 404 is no session', () async {
      final api = _api(
        (_) => http.Response(
          jsonEncode({'error': 'no watch session'}),
          404,
          headers: _json,
        ),
      );
      expect(await api.getWatchSession('c1'), isNull);
    });
  });

  test('one unreadable message does not sink the page', () async {
    final api = _api(
      (_) => http.Response(
        jsonEncode([
          _message('m1'),
          {..._message('m2'), 'poll': 'not a poll'},
          _message('m3'),
        ]),
        200,
        headers: _json,
      ),
    );
    final page = await api.listMessages('c1');
    expect(page.map((m) => m.id), ['m1', 'm3']);
  });

  test('a page reports its raw count and oldest raw seq past a skipped item',
      () async {
    final api = _api(
      (_) => http.Response(
        jsonEncode([
          {..._message('m3'), 'seq': 3},
          {..._message('m2'), 'seq': 2, 'poll': 'not a poll'},
        ]),
        200,
        headers: _json,
      ),
    );
    final page = await api.listMessagePage('c1', limit: 2);
    expect(page.messages.map((m) => m.id), ['m3']);
    expect(page.rawCount, 2);
    expect(page.minRawSeq, 2);
    expect(page.isShort(2), isFalse);
  });

  group('creates that a lost reply can retry', () {
    test('createRole sends the sheet id', () async {
      late Map<String, dynamic> body;
      final api = _api((request) {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'r1',
            'name': 'Mods',
            'permissions': 0,
            'position': 1,
            'is_everyone': false,
            'created_at': 1,
            'mentionable': false,
          }),
          200,
          headers: _json,
        );
      });
      await api.createRole(id: 'r1', name: 'Mods', permissions: 0);
      expect(body['id'], 'r1');
    });

    test('an emoji upload that already landed reads as success', () async {
      const bytes = [1, 2, 3];
      final api = _api((request) {
        final path = request.url.path;
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'error': 'an emoji with that name already exists'}),
            409,
            headers: _json,
          );
        }
        if (path == '/emoji') {
          return http.Response(
            jsonEncode([
              {'id': 'e1', 'name': 'cat', 'uploader_id': 'me', 'created_at': 1},
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response.bytes(bytes, 200,
            headers: {'content-type': 'image/png'});
      });
      final emoji = await api.uploadCustomEmoji(bytes, name: 'Cat');
      expect(emoji.id, 'e1');
    });

    test('an emoji name held by different bytes stays a conflict', () async {
      final api = _api((request) {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'error': 'an emoji with that name already exists'}),
            409,
            headers: _json,
          );
        }
        if (request.url.path == '/emoji') {
          return http.Response(
            jsonEncode([
              {'id': 'e1', 'name': 'cat', 'uploader_id': 'me', 'created_at': 1},
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response.bytes([9], 200,
            headers: {'content-type': 'image/png'});
      });
      await expectLater(
        api.uploadCustomEmoji([1, 2, 3], name: 'cat'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('a follow-up fetch that fails any other way keeps the conflict',
        () async {
      for (final (path, upload)
          in <(String, Future<Object?> Function(SlimmApi))>[
        ('/emoji', (api) => api.uploadCustomEmoji([1], name: 'cat')),
        ('/soundboard', (api) => api.uploadSoundClip([1], name: 'cat')),
      ]) {
        final api = _api((request) {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({'error': 'that name already exists'}),
              409,
              headers: _json,
            );
          }
          return http.Response(jsonEncode({'not': 'a list'}), 200,
              headers: _json);
        });
        await expectLater(
          upload(api),
          throwsA(isA<ConflictException>()),
          reason: path,
        );
      }
    });

    test('a clip upload that already landed reads as success', () async {
      const bytes = [7, 7];
      final api = _api((request) {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'error': 'a clip with that name already exists'}),
            409,
            headers: _json,
          );
        }
        if (request.url.path == '/soundboard') {
          return http.Response(
            jsonEncode([
              {
                'id': 'k1',
                'name': 'airhorn',
                'duration_ms': 900,
                'uploader_id': 'me',
                'created_at': 1,
              },
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response.bytes(bytes, 200,
            headers: {'content-type': 'audio/mpeg'});
      });
      final clip = await api.uploadSoundClip(bytes, name: 'airhorn');
      expect(clip.id, 'k1');
    });
  });
}
