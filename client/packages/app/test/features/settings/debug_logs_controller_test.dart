// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug logs controller: paging backward with `before`, a failed page
/// keeping what is shown, and deleting the last loaded row.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/debug_logs_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'admin-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(int id) => {
  'id': id,
  'user_id': 'u$id',
  'username': 'user$id',
  'display_name': 'Member $id',
  'note': '',
  'app_version': '0.1.0+1',
  'platform': 'linux',
  'size_bytes': 2048,
  'created_at': 1,
};

List<Map<String, dynamic>> _page(int newest, int count) => [
  for (var i = 0; i < count; i++) _entry(newest - i),
];

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig(http.Response Function(http.Request) answer) {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          queries.add(request.method == 'GET' ? request.url.query : 'delete');
          return answer(request);
        }),
      ],
    );
    container.listen(debugLogsControllerProvider, (_, _) {});
  }

  late final ProviderContainer container;
  final queries = <String>[];

  DebugLogsState get state => container.read(debugLogsControllerProvider);

  DebugLogsController get controller =>
      container.read(debugLogsControllerProvider.notifier);

  Future<void> settled() async {
    for (var i = 0; i < 200 && state.loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(state.loading, isFalse);
  }
}

Future<_Rig> _rig(http.Response Function(http.Request) answer) async {
  final rig = _Rig(answer);
  addTearDown(rig.container.dispose);
  await rig.settled();
  return rig;
}

void main() {
  test('load more asks before the oldest id and appends the page', () async {
    final rig = await _rig(
      (request) => request.url.queryParameters.containsKey('before')
          ? _json(_page(50, 3))
          : _json(_page(100, debugLogsPageSize)),
    );
    expect(rig.state.items, hasLength(debugLogsPageSize));
    expect(rig.state.more, isTrue);

    await rig.controller.loadMore();

    expect(rig.queries.last, contains('before=51'));
    expect(rig.state.items.map((e) => e.id).last, 48);
    expect(rig.state.items, hasLength(debugLogsPageSize + 3));
    expect(rig.state.more, isFalse);
  });

  test('a failed load more keeps the rows shown and says why', () async {
    final rig = await _rig(
      (request) => request.url.queryParameters.containsKey('before')
          ? _json({'error': 'nope'}, 500)
          : _json(_page(100, debugLogsPageSize)),
    );

    await rig.controller.loadMore();

    expect(rig.state.items, hasLength(debugLogsPageSize));
    expect(rig.state.error, isNotNull);
    expect(rig.state.more, isTrue);
  });

  test('deleting every loaded row reloads when older logs remain', () async {
    var deletes = 0;
    final rig = await _rig((request) {
      if (request.method == 'DELETE') {
        deletes++;
        return http.Response('', 204);
      }
      return _json(deletes == 0 ? _page(100, debugLogsPageSize) : _page(50, 5));
    });

    for (final entry in rig.state.items.toList()) {
      await rig.controller.delete(entry.id);
    }
    await rig.settled();

    expect(rig.state.items.map((e) => e.id), [50, 49, 48, 47, 46]);
  });
}
