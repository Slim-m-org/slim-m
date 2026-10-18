// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Catch-up asks `/sync` about more channels than the server accepts in one
/// request by chunking the cursors, keeping each chunk's progress.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/providers/sync_controller.dart';

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

const _serverLimit = 200;

List<String> _scopes(http.Request request) =>
    ((jsonDecode(request.body) as Map<String, dynamic>)['scopes'] as List)
        .map((s) => (s as Map<String, dynamic>)['channel_id'] as String)
        .toList();

Map<String, dynamic> _delta(String id, {bool hasMore = false}) => {
  'channel_id': id,
  'messages': <dynamic>[],
  'has_more': hasMore,
  'reset': false,
};

void main() {
  test('450 channels are caught up in requests of at most the server limit '
      'and every scope is answered', () async {
    final requests = <List<String>>[];
    final rig = await SyncLiveRig.build(
      (router) => router.on('POST', '/sync', (request) {
        final scopes = _scopes(request);
        requests.add(scopes);
        if (scopes.length > _serverLimit) {
          return http.Response('{"error":"too many scopes"}', 400);
        }
        return jsonResponse({'scopes': scopes.map(_delta).toList()});
      }),
      seeded: const [],
      extraChannels: 449,
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    expect(rig.status.name, 'live');
    expect(requests.length, greaterThanOrEqualTo(3));
    expect(requests.every((r) => r.length <= _serverLimit), isTrue);
    expect(requests.expand((r) => r).toSet().length, 450);
  });

  test('a later round sends only the scope that reported more', () async {
    final requests = <List<String>>[];
    final rig = await SyncLiveRig.build(
      (router) => router.on('POST', '/sync', (request) {
        final scopes = _scopes(request);
        requests.add(scopes);
        final firstPass = requests.length <= 3;
        return jsonResponse({
          'scopes': [
            for (final id in scopes)
              _delta(id, hasMore: firstPass && id == 'x7'),
          ],
        });
      }),
      seeded: const [],
      extraChannels: 449,
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    expect(requests.length, greaterThan(3));
    expect(requests[3], ['x7']);
  });

  test('a failed chunk is retried and the chunks before it are kept', () async {
    final requests = <List<String>>[];
    var failedOnce = false;
    final rig = await SyncLiveRig.build(
      (router) => router.on('POST', '/sync', (request) {
        final scopes = _scopes(request);
        requests.add(scopes);
        if (scopes.length < _serverLimit && !failedOnce) {
          failedOnce = true;
          return http.Response('{"error":"boom"}', 500);
        }
        return jsonResponse({
          'scopes': [
            for (final id in scopes)
              if (id == 'c1')
                {
                  ..._delta(id),
                  'messages': [rigMessage('m1', 1, 'first chunk landed')],
                }
              else
                _delta(id),
          ],
        });
      }),
      seeded: const [],
      extraChannels: 199,
      overrides: [
        syncChunkRetryDelaysProvider.overrideWithValue(const [Duration.zero]),
      ],
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    expect(failedOnce, isTrue);
    expect(rig.status.name, 'live');
    expect((await rig.contents())['m1'], 'first chunk landed');
    expect(requests.where((r) => r.length == 50).length, 2);
  });
}
