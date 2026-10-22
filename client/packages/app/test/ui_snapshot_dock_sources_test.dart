// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock with an official source, a community source (one module whose id
/// the official source owns) and a community source that failed to load, at
/// phone and desktop in both themes.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

Map<String, Object> _entry(
  String id,
  String name,
  String summary, {
  bool shadowed = false,
}) => {
  'id': id,
  'name': name,
  'version': '0.1.0',
  'summary': summary,
  'shadowed': shadowed,
};

final _installed = {
  'id': 'extra-dice',
  'name': 'Dice Roller',
  'version': '0.1.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>['command.register'],
  'extension_points': <Object>[],
  'enabled': true,
  'installed_at': 1000,
  'source_repo': 'acme/mods',
};

api.SlimmApi _dock(Ref ref) => testApi((request) async {
  final key = '${request.url.path}?${request.url.query}';
  final (int, Object)? answer = switch (key) {
    '/space/dock/sources?' => (
      200,
      [
        {'id': 'official', 'repo': 'Slim-m-org/slim-addons', 'official': true},
        {'id': 's1', 'repo': 'acme/mods', 'official': false},
        {'id': 's2', 'repo': 'somebody/experiments', 'official': false},
      ],
    ),
    '/space/dock/modules?' => (
      200,
      [
        _entry(
          'code-exec',
          'Code Blocks',
          'Run code snippets in a channel and post the output.',
        ),
      ],
    ),
    '/space/dock/modules?source=s1' => (
      200,
      [
        _entry(
          'extra-dice',
          'Dice Roller',
          'Roll dice with /roll and share the result.',
        ),
        _entry(
          'code-exec',
          'Code Blocks (fork)',
          'A fork of the official module.',
          shadowed: true,
        ),
      ],
    ),
    '/space/dock/modules?source=s2' => (502, {'error': 'bad index'}),
    '/space/dock/installed?' => (200, [_installed]),
    _ => null,
  };
  if (answer == null) return fixtureResponse(request);
  return http.Response(
    jsonEncode(answer.$2),
    answer.$1,
    headers: {'content-type': 'application/json'},
  );
}, session: ref.watch(sessionProvider));

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const [darkAndLight]) {
    for (final viewport in phoneAndDesktop) {
      testWidgets('dock-sources at $viewport ($theme) fits', (tester) async {
        await renderSurface(
          tester,
          '/settings/dock',
          viewport,
          theme,
          'dock-sources-$viewport-$theme',
          overrides: [apiProvider.overrideWith(_dock)],
          settleNestedResolve: true,
        );
      });
    }
  }
}
