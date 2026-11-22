// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire for shared room state (decision 0131): the `module.room` frame,
/// the room list and the input route.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request request) handler) =>
    SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('module.room carries the state, or null and how the room ended', () {
    final live = ServerEvent.parse(
      jsonEncode({
        'type': 'module.room',
        'channel_id': 'c1',
        'module_id': 'noughts',
        'seq': 3,
        'state': {'board': 'x...o....'},
      }),
    )! as ModuleRoomChanged;
    expect((live.channelId, live.moduleId, live.seq), ('c1', 'noughts', 3));
    expect((live.state! as Map)['board'], 'x...o....');
    expect(live.ended, isNull);

    final ended = ServerEvent.parse(
      jsonEncode({
        'type': 'module.room',
        'channel_id': 'c1',
        'module_id': 'noughts',
        'seq': 3,
        'state': null,
        'ended': 'call_ended',
      }),
    )! as ModuleRoomChanged;
    expect(ended.state, isNull);
    expect(ended.ended, 'call_ended');
  });

  test('a module.room frame missing its ids is ignored', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'module.room', 'channel_id': 'c1', 'seq': 1}),
    );
    expect(event, isNot(isA<ModuleRoomChanged>()));
  });

  test('the room list skips an entry it cannot read', () async {
    late http.Request seen;
    final rooms = await _api((request) async {
      seen = request;
      return _json({
        'rooms': [
          {
            'module_id': 'noughts',
            'seq': 2,
            'state': 'any json',
            'updated_at_ms': 5,
          },
          {'module_id': 7},
        ],
      });
    }).moduleRooms('c1');
    expect(seen.method, 'GET');
    expect(seen.url.path, '/channels/c1/module-rooms');
    expect(rooms.single.moduleId, 'noughts');
    expect((rooms.single.seq, rooms.single.state), (2, 'any json'));
    expect(rooms.single.updatedAtMs, 5);
  });

  test('an input posts the text and reads what the module did', () async {
    late http.Request seen;
    final result = await _api((request) async {
      seen = request;
      return _json({
        'applied': false,
        'seq': 2,
        'state': {'board': 'x...o....'},
        'reason': 'not your turn',
      });
    }).sendModuleRoomInput('c1', 'noughts', '1');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/channels/c1/module-rooms/noughts/inputs');
    expect(jsonDecode(seen.body), {'input': '1'});
    expect(result.applied, isFalse);
    expect(result.reason, 'not your turn');
    expect(result.ended, isFalse);
    expect(
      ModuleRoomInputResult.fromJson({
        'applied': true,
        'seq': 0,
        'state': null,
      }).ended,
      isTrue,
    );
  });
}
