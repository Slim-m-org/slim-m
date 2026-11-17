// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard: its model, its calls, and the frame that tells a call to
/// play a clip.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

const _horn = '\u{1F4EF}';

const _clip = {
  'id': 'clip-1',
  'name': 'Air horn',
  'duration_ms': 1500,
  'uploader_id': 'user-1',
  'created_at': 7,
};

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

void main() {
  test('a clip parses every field, and a deleted uploader is null', () {
    final clip = SoundClip.fromJson(_clip);
    expect((
      clip.id,
      clip.name,
      clip.durationMs,
      clip.createdAt
    ), (
      'clip-1',
      'Air horn',
      1500,
      7,
    ));
    expect(
        SoundClip.fromJson({..._clip, 'uploader_id': null}).uploaderId, isNull);
  });

  test(
      'a clip carries its emoji, and one without, or from an older server, has none',
      () {
    expect(SoundClip.fromJson({..._clip, 'emoji': _horn}).emoji, _horn);
    expect(SoundClip.fromJson({..._clip, 'emoji': null}).emoji, isNull);
    expect(SoundClip.fromJson(_clip).emoji, isNull);
  });

  test('listing reads GET /soundboard', () async {
    String? path;
    final api = _api((request) async {
      path = request.url.path;
      return http.Response(jsonEncode([_clip]), 200);
    });
    expect((await api.listSoundClips()).single.name, 'Air horn');
    expect(path, '/soundboard');
  });

  test('uploading sends the raw bytes with the name in the query', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(jsonEncode(_clip), 201);
    });
    final clip = await api.uploadSoundClip(const [1, 2, 3], name: 'Air horn');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/soundboard');
    expect(seen.url.queryParameters['name'], 'Air horn');
    expect(seen.bodyBytes, [1, 2, 3]);
    expect(seen.url.queryParameters.containsKey('emoji'), isFalse);
    expect(clip.id, 'clip-1');
  });

  test('uploading with an emoji puts it in the query beside the name',
      () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(
        jsonEncode({..._clip, 'emoji': _horn}),
        201,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final clip =
        await api.uploadSoundClip(const [1], name: 'Air horn', emoji: _horn);
    expect(seen.url.queryParameters['emoji'], _horn);
    expect(clip.emoji, _horn);
  });

  test('an update sends only what changes, and clearing sends a null emoji',
      () async {
    final bodies = <Object?>[];
    final api = _api((request) async {
      bodies.add(jsonDecode(request.body));
      return http.Response(jsonEncode(_clip), 200);
    });
    await api.renameSoundClip('clip-1', emoji: ':honk:');
    await api.renameSoundClip('clip-1', clearEmoji: true);
    await api.renameSoundClip('clip-1', name: 'Honk', emoji: _horn);
    expect(bodies, [
      {'emoji': ':honk:'},
      {'emoji': null},
      {'name': 'Honk', 'emoji': _horn},
    ]);
  });

  test('renaming patches the clip, deleting removes it, playing posts',
      () async {
    final seen = <String>[];
    final api = _api((request) async {
      seen.add('${request.method} ${request.url.path} ${request.body}');
      return request.method == 'PATCH'
          ? http.Response(jsonEncode(_clip), 200)
          : http.Response('', 204);
    });
    await api.renameSoundClip('clip-1', name: 'Honk');
    await api.deleteSoundClip('clip-1');
    await api.playSoundClip('chan-1', 'clip-1');
    expect(seen, [
      'PATCH /soundboard/clip-1 {"name":"Honk"}',
      'DELETE /soundboard/clip-1 ',
      'POST /channels/chan-1/voice/soundboard/clip-1/play ',
    ]);
  });

  test('a soundboard.played frame parses, and one missing a field does not',
      () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'soundboard.played',
        'channel_id': 'c1',
        'clip_id': 'clip-1',
        'player_id': 'user-2',
      }),
    );
    expect(event, isA<SoundboardPlayed>());
    final played = event as SoundboardPlayed;
    expect((
      played.channelId,
      played.clipId,
      played.playerId
    ), (
      'c1',
      'clip-1',
      'user-2',
    ));
    expect(
      ServerEvent.parse(
          jsonEncode({'type': 'soundboard.played', 'channel_id': 'c1'})),
      isNot(isA<SoundboardPlayed>()),
    );
  });
}
