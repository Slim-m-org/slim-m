// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One fake community for the soak harness: its channels, members and recent
/// messages, and the REST answers the shell asks for.
///
/// It holds a fixed amount however long the run is: each channel keeps only
/// its newest [historyKept] messages, so anything that grows during a soak is
/// the app's, not the harness's.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;

import '../support/synthetic_png.dart';
import '../ui_snapshot_fixture_data.dart' show fixtureResponse;

const _phrases = [
  'did anyone look at the build from last night',
  'yes, it is green again',
  'the rail lines up at every width now',
  'joining the call in five',
  'https://example.com/notes has the write-up',
  'that is the second time this week',
  'ok, pushing a fix',
  'can someone review the canvas change',
  'lunch?',
  'this one is long enough to wrap onto a second line in a narrow pane, '
      'which is the case a transcript row has to measure for',
];

class SoakWorld {
  SoakWorld({
    required this.name,
    required int seed,
    this.textChannels = 40,
    this.voiceChannels = 6,
    this.dms = 8,
    this.members = 500,
    this.historyKept = 120,
  }) : _random = Random(seed) {
    for (var i = 0; i < textChannels; i++) {
      _add(
        api.Channel(
          id: '$name-t$i',
          name: 'text-$i',
          kind: 'text',
          createdAt: 0,
          categoryId: '$name-cat-text',
          position: i,
        ),
      );
    }
    for (var i = 0; i < voiceChannels; i++) {
      _add(
        api.Channel(
          id: '$name-v$i',
          name: 'voice-$i',
          kind: 'voice',
          createdAt: 0,
          categoryId: '$name-cat-voice',
          position: i,
        ),
      );
    }
    for (var i = 0; i < dms; i++) {
      _add(
        api.Channel(
          id: '$name-d$i',
          name: 'Member ${i + 1}',
          kind: 'dm',
          createdAt: 0,
          dmParticipantId: userId(i + 1),
        ),
      );
    }
    for (var i = 0; i < members; i++) {
      presence[userId(i)] = i % 3 == 0 ? 'online' : 'offline';
    }
  }

  final String name;
  final int textChannels;
  final int voiceChannels;
  final int dms;
  final int members;
  final int historyKept;
  final Random _random;

  final channels = <api.Channel>[];
  final presence = <String, String>{};
  final voice = <String, Set<String>>{};
  final _history = <String, List<Map<String, dynamic>>>{};
  final _seq = <String, int>{};
  var _nextId = 0;

  /// Simulated wall time for message stamps, advanced by the driver.
  int nowMs = 1760000000000;

  String get selfId => userId(0);
  String userId(int i) => '$name-u$i';

  List<api.ChannelCategory> get categories => [
    api.ChannelCategory(
      id: '$name-cat-text',
      name: 'Text',
      position: 0,
      createdAt: 0,
    ),
    api.ChannelCategory(
      id: '$name-cat-voice',
      name: 'Voice',
      position: 1,
      createdAt: 0,
    ),
  ];

  List<String> get textChannelIds => [
    for (final c in channels)
      if (c.kind != 'voice') c.id,
  ];

  List<String> get voiceChannelIds => [
    for (final c in channels)
      if (c.kind == 'voice') c.id,
  ];

  void _add(api.Channel channel) {
    channels.add(channel);
    _history[channel.id] = [];
    _seq[channel.id] = 0;
    if (channel.kind == 'voice') voice[channel.id] = {};
  }

  String randomMember() => userId(1 + _random.nextInt(members - 1));

  /// Seeds every text channel with [count] messages, for the first paint.
  void seedHistory(int count) {
    for (final id in textChannelIds) {
      for (var i = 0; i < count; i++) {
        nextMessage(id);
      }
    }
  }

  /// The next message in [channelId], recorded as the server's newest.
  Map<String, dynamic> nextMessage(String channelId, {String? authorId}) {
    final author = authorId ?? randomMember();
    final seq = _seq[channelId] = _seq[channelId]! + 1;
    final message = <String, dynamic>{
      'id': '$name-m${_nextId++}',
      'channel_id': channelId,
      'author_id': author,
      'author_display_name': 'Member ${author.split('-u').last}',
      'seq': seq,
      'content': _phrases[_random.nextInt(_phrases.length)],
      'created_at': nowMs,
      'edited_at': null,
    };
    final history = _history[channelId]!..add(message);
    if (history.length > historyKept) history.removeAt(0);
    return message;
  }

  /// A recent message of [channelId], for an edit, a reaction or a delete.
  Map<String, dynamic>? recentMessage(String channelId) {
    final history = _history[channelId]!;
    if (history.isEmpty) return null;
    return history[history.length -
        1 -
        _random.nextInt(min(10, history.length))];
  }

  void forget(String channelId, String messageId) =>
      _history[channelId]!.removeWhere((m) => m['id'] == messageId);

  Map<String, dynamic> _member(String id) => {
    'id': id,
    'username': id,
    'display_name': 'Member ${id.split('-u').last}',
    'created_at': 0,
    'roles': id == selfId ? ['admin'] : <String>[],
    // Every fifth member has a picture, so the avatar path decodes real bytes.
    'avatar_updated_at': _hasAvatar(id) ? 1 : null,
  };

  bool _hasAvatar(String id) => int.parse(id.split('-u').last) % 5 == 0;

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  /// REST paths asked for, by shape; a run prints the busiest so a refetch loop shows.
  final requests = <String, int>{};

  MockClient client() => MockClient(_respond);

  Future<http.Response> _respond(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    final shape = path.replaceAll(RegExp('$name-[a-z]+[0-9]+'), ':id');
    requests[shape] = (requests[shape] ?? 0) + 1;
    if (path == '/me') {
      return _json({..._member(selfId), 'permissions': -1});
    }
    if (path == '/users') {
      final ids = (query['ids'] ?? '').split(',');
      return _json([
        for (final id in ids)
          if (presence.containsKey(id)) _member(id),
      ]);
    }
    if (path == '/members') {
      final limit = int.tryParse(query['limit'] ?? '') ?? 100;
      final after = query['after'];
      final start = after == null ? 0 : int.parse(after.split('-u').last) + 1;
      return _json([
        for (var i = start; i < min(members, start + limit); i++)
          _member(userId(i)),
      ]);
    }
    if (path == '/presence' && request.method == 'GET') {
      final ids = (query['ids'] ?? '').split(',');
      return _json([
        for (final id in ids)
          if (presence[id] case final status?)
            {'user_id': id, 'status': status},
      ]);
    }
    if (path == '/channels') {
      return _json([
        for (final c in channels)
          {
            'id': c.id,
            'name': c.name,
            'kind': c.kind,
            'created_at': 0,
            'category_id': c.categoryId,
            'position': c.position,
          },
      ]);
    }
    final parts = path.split('/');
    if (parts.length == 4 && parts[1] == 'channels' && parts[3] == 'messages') {
      final history = _history[parts[2]] ?? const [];
      final before = int.tryParse(query['before'] ?? '');
      final limit = int.tryParse(query['limit'] ?? '') ?? 50;
      final page = [
        for (final m in history.reversed)
          if (before == null || (m['seq'] as int) < before) m,
      ];
      return _json(page.take(limit).toList());
    }
    if (path.endsWith('/voice/roster')) {
      return _json({
        'participants': [
          for (final id in voice[parts[2]] ?? const <String>{})
            {'user_id': id, 'display_name': 'Member ${id.split('-u').last}'},
        ],
      });
    }
    if (path.endsWith('/read')) {
      return _json({'last_read_seq': _seq[parts[2]] ?? 0, 'unread': 0});
    }
    if (path.endsWith('/avatar') && parts.length == 4) {
      if (!_hasAvatar(parts[2])) {
        return http.Response('{"error":"user has no avatar"}', 404);
      }
      final shade = int.parse(parts[2].split('-u').last) % 200;
      return http.Response.bytes(
        solidPng(64, 64, shade: shade),
        200,
        headers: const {'content-type': 'image/png'},
      );
    }
    return fixtureResponse(request);
  }
}
