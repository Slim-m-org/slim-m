// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Temporary voice rooms on the wire (decision 0065): the channel fields, and
/// the two room routes' requests.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _room = {
  'id': 'room-1',
  'name': "alice's room",
  'kind': 'voice',
  'created_at': 1,
  'creates_rooms': false,
  'user_limit': 4,
  'room_owner_id': 'alice',
  'room_locked': true,
};

SlimmApi _api(List<http.Request> seen) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'alice',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode(_room),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

void main() {
  test('a room parses its owner, lock and limit', () {
    final room = Channel.fromJson(_room);
    expect(room.isRoom, isTrue);
    expect(room.roomOwnerId, 'alice');
    expect(room.roomLocked, isTrue);
    expect(room.userLimit, 4);
  });

  test('a channel from an older server is no lobby, no room, no limit', () {
    final plain = Channel.fromJson({
      'id': 'c',
      'name': 'voice',
      'kind': 'voice',
      'created_at': 1,
    });
    expect(plain.createsRooms, isFalse);
    expect(plain.isRoom, isFalse);
    expect(plain.userLimit, 0);
  });

  test(
      'opening a room posts to the lobby, and updating sends only what changed',
      () async {
    final seen = <http.Request>[];
    final api = _api(seen);
    await api.openVoiceRoom('lobby');
    await api.updateVoiceRoom(channelId: 'room-1', locked: true);
    await api.updateChannel(
        channelId: 'lobby', createsRooms: true, userLimit: 0);
    expect(seen[0].method, 'POST');
    expect(seen[0].url.path, '/channels/lobby/voice/room');
    expect(seen[1].method, 'PATCH');
    expect(seen[1].url.path, '/channels/room-1/room');
    expect(jsonDecode(seen[1].body), {'locked': true});
    expect(jsonDecode(seen[2].body), {'creates_rooms': true, 'user_limit': 0});
  });
}
