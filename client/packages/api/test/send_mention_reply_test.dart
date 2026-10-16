// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply says whether it also mentions the author it answers; a plain
/// message never carries the field.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> _sentBody({
  String? replyToId,
  bool? mentionReply,
}) async {
  late Map<String, dynamic> body;
  final api = SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: SessionStore(
      tokens: const TokenPair(
        userId: 'u1',
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: 4102444800000,
      ),
    ),
    httpClient: MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'id': 'm1',
          'channel_id': 'c1',
          'author_id': 'u1',
          'author_display_name': 'Me',
          'seq': 1,
          'content': 'hi',
          'created_at': 0,
          'edited_at': null,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  await api.sendMessage(
    channelId: 'c1',
    id: 'm1',
    content: 'hi',
    replyToId: replyToId,
    mentionReply: mentionReply ?? true,
  );
  return body;
}

void main() {
  test('a reply defaults to mentioning its author', () async {
    final body = await _sentBody(replyToId: 'p1');
    expect(body['mention_reply'], isTrue);
  });

  test('a reply can opt out of the mention', () async {
    final body = await _sentBody(replyToId: 'p1', mentionReply: false);
    expect(body['reply_to_id'], 'p1');
    expect(body['mention_reply'], isFalse);
  });

  test('a plain message never carries mention_reply', () async {
    final body = await _sentBody(mentionReply: false);
    expect(body.containsKey('mention_reply'), isFalse);
  });
}
