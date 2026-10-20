// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fake server, the provider container and the widget slot the profile run shows the pane in.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../test/support/fake_blocks.dart';
import '../test/support/fake_sync.dart';
import 'perf_voice.dart';

const tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<http.Response> answer(http.Request request) async {
  final path = request.url.path;
  if (path.endsWith('/me')) {
    return jsonResponse({
      'id': 'me',
      'username': 'me',
      'display_name': 'Me',
      'created_at': 0,
      'permissions': Perm.manageCanvas,
    });
  }
  if (path.endsWith('/permissions')) {
    return jsonResponse({'permissions': Perm.manageCanvas});
  }
  if (path.endsWith('/canvas/ops') && request.method == 'POST') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'op': {
          'id': 'op',
          'seq': 1,
          'kind': body['kind'],
          'affected': 1,
          'created_at': 0,
        },
        'fresh': true,
      }),
      201,
      headers: {'content-type': 'application/json'},
    );
  }
  if (path.endsWith('/canvas/ops')) {
    return jsonResponse({
      'ops': <Object>[],
      'latest_seq': 0,
      'has_more': false,
      'reset': false,
    });
  }
  if (path.endsWith('/canvas/media-slots')) {
    return jsonResponse({'slots': <Object>[]});
  }
  if (path.endsWith('/canvas/object-locks')) {
    return jsonResponse({'object_ids': <Object>[]});
  }
  if (path.endsWith('/canvas/objects') && request.method == 'POST') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'kind': body['kind'],
        'z_index': 1,
        'x': body['x'],
        'y': body['y'],
        'w': body['w'],
        'h': body['h'],
        'props': body['props'],
        'author_id': 'me',
        'seq': 1,
        'created_at': 0,
      }),
      201,
      headers: {'content-type': 'application/json'},
    );
  }
  if (path.endsWith('/canvas/objects')) {
    return jsonResponse({
      'objects': <Object>[],
      'has_more': false,
      'latest_seq': 0,
    });
  }
  return jsonResponse(<Object>[]);
}

PerfVoice? voice;
final serverEvents = StreamController<api.ServerEvent>.broadcast();

ProviderContainer makeContainer(int participants) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
    syncControllerProvider.overrideWith(NoopSyncController.new),
    liveEventsProvider.overrideWithValue(serverEvents.stream),
    apiProvider.overrideWith((ref) {
      final client = testApi(answer, session: ref.watch(sessionProvider));
      ref.onDispose(client.close);
      return client;
    }),
    voiceControllerProvider.overrideWith((ref) {
      return voice = PerfVoice(ref, callOf(participants));
    }),
    blocksProvider.overrideWith(
      (ref) => FixedBlocksController(ref, const BlocksState()),
    ),
  ],
);

class Host extends ChangeNotifier {
  Widget? child;

  void show(Widget next) {
    child = next;
    notifyListeners();
  }
}

final host = Host();
