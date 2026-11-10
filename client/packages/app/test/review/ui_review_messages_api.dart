// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fake server the messages review suites run against: the fixture's own
/// answers plus the bot and webhook profiles a transcript names, the reactors
/// a reaction popover lists, and the channel permissions of an administrator
/// (without which a row offers no reply, edit or forward).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart'
    show jsonHttpResponse;

import '../ui_snapshot_support.dart';

const _extraProfiles = [
  {
    'id': 'user-bot',
    'username': 'reminderbot',
    'display_name': 'Reminder Bot',
    'created_at': 0,
    'roles': <String>[],
    'is_bot': true,
  },
  {
    'id': 'user-hook',
    'username': 'deployhook',
    'display_name': 'Deploy Hook',
    'created_at': 0,
    'roles': <String>[],
    'is_webhook': true,
  },
];

/// Answers [route] first when it returns a response, then the fixture's own
/// answers, with the review bot added to the member reads.
Override reviewApi([
  FutureOr<http.Response?> Function(http.Request request)? route,
]) => apiProvider.overrideWith((ref) {
  final client = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: _ReviewClient(route),
  );
  ref.onDispose(client.close);
  return client;
});

class _ReviewClient extends http.BaseClient {
  _ReviewClient(this._route);

  final FutureOr<http.Response?> Function(http.Request request)? _route;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final plain = http.Request(request.method, request.url)
      ..bodyBytes = await request.finalize().toBytes()
      ..headers.addAll(request.headers);
    final answer = await _route?.call(plain) ?? await _fixture(plain);
    return http.StreamedResponse(
      Stream.value(answer.bodyBytes),
      answer.statusCode,
      headers: answer.headers,
      request: request,
    );
  }

  Future<http.Response> _fixture(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == '/channels') return jsonHttpResponse(_visibleChannels);
      if (path == '/dms') return jsonHttpResponse(_dms);
      if (path.endsWith('/permissions')) {
        return jsonHttpResponse({'permissions': -1});
      }
    }
    final answer = await fixtureResponse(request);
    if (path != '/users') return answer;
    final asked = request.url.queryParameters['ids']?.split(',') ?? const [];
    final people = (jsonDecode(answer.body) as List<dynamic>)
      ..addAll(_extraProfiles)
      ..addAll([
        for (final id in asked)
          if (id.startsWith(_reactorPrefix)) _reactorProfile(id),
      ]);
    return jsonHttpResponse(people);
  }
}

const _reactorPrefix = 'user-react-';

const _reactorNames = [
  'Grace Hopper',
  'Alan Turing',
  'Margaret Hamilton',
  'Linus Torvalds',
  'Katherine Johnson',
  'Dennis Ritchie',
  'Radia Perlman',
  'Ken Thompson',
  'Barbara Liskov',
  'Donald Knuth',
  'Frances Allen',
  'Edsger Dijkstra',
  'Shafi Goldwasser',
  'Bjarne Stroustrup',
  'Sophie Wilson',
  'Guido van Rossum',
  'Anita Borg',
  'Rob Pike',
  'Lynn Conway',
  'John McCarthy',
];

/// The id of the [index]th person who left a reaction in the review data.
String reviewReactor(int index) => '$_reactorPrefix$index';

Map<String, Object?> _reactorProfile(String id) {
  final index = int.parse(id.substring(_reactorPrefix.length));
  final name = _reactorNames[index % _reactorNames.length];
  return {
    'id': id,
    'username': name.toLowerCase().replaceAll(' ', '.'),
    'display_name': name,
    'created_at': 0,
    'roles': <String>[],
  };
}

/// The channel list as the server sends it to an administrator: every
/// ordinary channel with the caller's full permission bitmask on it.
final _visibleChannels = [
  for (final c in fixtureChannels)
    if (c.kind != 'dm' && !c.isThread)
      {
        'id': c.id,
        'name': c.name,
        'kind': c.kind,
        'created_at': c.createdAt,
        'topic': c.topic,
        'category_id': c.categoryId,
        'join_muted': c.joinMuted,
        'permissions': -1,
        'restricted': false,
      },
];

const _dms = [
  {
    'channel_id': 'c-dm-ada',
    'user': {
      'id': 'user-ada',
      'username': 'ada',
      'display_name': 'Ada Lovelace',
      'created_at': 0,
      'roles': <String>[],
    },
    'unread': 0,
    'created_at': 0,
  },
];
