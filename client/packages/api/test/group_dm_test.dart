// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Group DM routes (decision 0095): the wire shapes, and the `dm.changed` frame.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'u1',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

Map<String, Object?> _user(String id, String name) => {
      'id': id,
      'username': name,
      'display_name': name,
      'created_at': 1,
    };

Map<String, Object?> _group({String? name}) => {
      'channel_id': 'g1',
      'user': _user('u2', 'ann'),
      'unread': 0,
      'created_at': 5,
      'group': {
        'name': name,
        'members': [_user('u1', 'me'), _user('u2', 'ann'), _user('u3', 'bo')],
      },
    };

void main() {
  test('a pair conversation has no group', () {
    final dm = DmConversation.fromJson({
      'channel_id': 'c1',
      'user': _user('u2', 'ann'),
      'unread': 0,
      'created_at': 5,
    });
    expect(dm.isGroup, isFalse);
    expect(dm.group, isNull);
  });

  test('a group conversation carries its roster and an optional name', () {
    final named = DmConversation.fromJson(_group(name: 'trip'));
    expect(named.isGroup, isTrue);
    expect(named.group!.name, 'trip');
    expect(named.group!.members.map((m) => m.id), ['u1', 'u2', 'u3']);
    expect(DmConversation.fromJson(_group()).group!.name, isNull);
  });

  test('the four group routes hit the documented paths with their bodies',
      () async {
    final seen = <String>[];
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        seen.add('${request.method} ${request.url.path} ${request.body}');
        if (request.url.path.endsWith('/leave')) {
          return http.Response('', 204);
        }
        return http.Response(jsonEncode(_group()), 200,
            headers: {'content-type': 'application/json'});
      }),
    );

    await api.createGroupDirectMessage(['u2', 'u3'], id: 'g1', name: 'trip');
    await api.addGroupDirectMessageMember('g1', 'u4');
    await api.renameGroupDirectMessage('g1', null);
    await api.leaveGroupDirectMessage('g1');

    expect(seen, [
      'POST /dms/groups {"id":"g1","user_ids":["u2","u3"],"name":"trip"}',
      'POST /dms/groups/g1/members {"user_id":"u4"}',
      'PATCH /dms/groups/g1 {"name":null}',
      'POST /dms/groups/g1/leave ',
    ]);
  });

  test('dm.changed decodes the channel id and ignores a frame without one', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'dm.changed', 'channel_id': 'g1'}),
    );
    expect((event! as DmChanged).channelId, 'g1');
    expect(ServerEvent.parse(jsonEncode({'type': 'dm.changed'})), isNull);
  });
}
