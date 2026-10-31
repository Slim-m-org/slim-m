// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hook list an admin reads and the one change they can make to a hook,
/// and the hooks a manifest declares for consent.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

void main() {
  test('moduleHooks reads the chain in the order the server sends it',
      () async {
    final api = _api((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/space/dock/hooks');
      return http.Response(
        jsonEncode([
          {
            'module_id': 'filter',
            'module_name': 'Filter',
            'kind': 'interceptor',
            'hook': 'message.pre_send',
            'phase': 'reject',
            'reads': ['content'],
            'priority': 100,
            'fail_closed': true,
            'live': true,
            'runs': 9,
            'failures': 2,
            'last_error': 'trapped',
            'max_fuel_used': 12,
          },
          {
            'module_id': 'gate',
            'module_name': 'Gate',
            'kind': 'permission',
            'hook': 'message.send',
            'phase': '',
            'priority': 50,
            'live': false,
          },
        ]),
        200,
      );
    });
    final hooks = await api.moduleHooks();
    expect(hooks.map((h) => h.moduleId), ['filter', 'gate']);
    expect(hooks.first.failClosed, isTrue);
    expect(hooks.first.reads, ['content']);
    expect(hooks.first.lastError, 'trapped');
    expect(hooks.last.live, isFalse);
    expect(hooks.last.runs, 0);
  });

  test('updateModuleHook sends only what changed', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response('', 204);
    });
    await api.updateModuleHook(
      'filter',
      kind: 'interceptor',
      hook: 'message.pre_send',
      phase: 'reject',
      priority: 120,
    );
    expect(seen.method, 'PUT');
    expect(seen.url.path, '/space/dock/modules/filter/hooks');
    expect(jsonDecode(seen.body), {
      'kind': 'interceptor',
      'hook': 'message.pre_send',
      'phase': 'reject',
      'priority': 120,
    });
  });

  test('a manifest lists the hooks it declares', () {
    final hooks = dockHooks(<Object>[
      {
        'hook': 'message.pre_edit',
        'phase': 'rewrite',
        'reads': ['content', 7],
      },
      'junk',
      {'hook': 'voice.join', 'reads': <String>[]},
    ]);
    expect(hooks.length, 2);
    expect(hooks.first.reads, ['content']);
    expect(hooks.last.phase, '');
    expect(dockHooks(null), isEmpty);
  });
}
