// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server with one Dock panel, `board`, whose scene counts the presses of
/// its step control. Shared by the panel's pane, page and entry tests.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;

import '../settings/home_shell_harness.dart';

const boardPanel = api.ModulePanel(
  moduleId: 'board',
  command: 'board',
  name: 'Board',
  description: 'A board beside the chat',
);

/// What the fake server was asked, and how it should answer.
class BoardServer {
  BoardServer({this.fails = false, this.refreshMs});

  /// The module answers `ok: false`, as a trap or a timeout does.
  bool fails;
  final int? refreshMs;
  final inputs = <String>[];

  int get firstRuns => inputs.where((i) => i.isEmpty).length;

  String _scene(int count) => jsonEncode({
    r'$slim': 'scene/1',
    'width': 40,
    'height': 10,
    'ops': [
      {'op': 'rect', 'x': 0, 'y': 0, 'w': 40, 'h': 10, 'fill': 'sunken'},
    ],
    'state': '$count',
    'status': 'Count $count',
    'controls': ['step'],
    if (refreshMs != null) 'refresh_ms': refreshMs,
  });

  Object _run(String input) {
    inputs.add(input);
    if (fails) return {'ok': false, 'error': 'module timed out'};
    if (input.isEmpty) return {'ok': true, 'output': _scene(0)};
    final asked = jsonDecode(input) as Map<String, Object?>;
    final held = int.tryParse('${asked['state']}') ?? 0;
    final next = asked['action'] == 'step' ? held + 1 : held;
    return {'ok': true, 'output': _scene(next)};
  }

  MockClient client() {
    final quiet = quietClient();
    return MockClient((request) async {
      final path = request.url.path;
      final Object? body = switch (path) {
        '/modules/panels' => [
          {
            'module_id': 'board',
            'command': 'board',
            'name': 'Board',
            'description': 'A board beside the chat',
            'module': {
              'name': 'Board',
              'verified': true,
              'capabilities': <String>[],
              'network_hosts': <String>[],
            },
          },
        ],
        '/modules/board/commands/board' => _run(
          (jsonDecode(request.body) as Map<String, Object?>)['input']!
              as String,
        ),
        _ => null,
      };
      if (body == null) {
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..body = request.body;
        return http.Response.fromStream(await quiet.send(copy));
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }
}
