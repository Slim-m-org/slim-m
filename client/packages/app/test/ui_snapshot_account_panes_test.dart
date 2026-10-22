// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captures of the Account & devices, Blocked and Report status panes in the
/// states the design frames show: stale devices, two-factor off and on, and
/// the empty and populated block list.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_app/src/routing/routes.dart';

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

Map<String, Object> _device(
  String id,
  String name,
  String kind,
  String version,
  Duration ago, {
  bool current = false,
}) => {
  'id': id,
  'name': name,
  'created_at': 1,
  'last_seen_at': DateTime.now().subtract(ago).millisecondsSinceEpoch,
  'client_kind': kind,
  'client_version': version,
  'is_current': current,
};

Map<String, Object> _totp({required bool on}) => {
  'enabled': on,
  'pending': false,
  'recovery_codes_remaining': on ? 8 : 0,
  'policy': 'optional',
};

api.SlimmApi _apiWith(Ref ref, Map<String, Object> paths) {
  final client = testApi((request) async {
    final body = paths[request.url.path];
    if (body == null) return fixtureResponse(request);
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }, session: ref.watch(sessionProvider));
  ref.onDispose(client.close);
  return client;
}

final _devices = [
  _device(
    'd1',
    'Linux - fedora',
    'desktop',
    '0.86.0',
    Duration.zero,
    current: true,
  ),
  _device('d2', 'iPhone', 'ios', '0.101.0', const Duration(hours: 8)),
  _device('d3', 'Old laptop', 'desktop', '0.70.0', const Duration(days: 20)),
];

void main() {
  setUpAll(loadRealFonts);

  final surfaces = <String, ({String pane, Map<String, Object> paths})>{
    'sr-account-totp-off': (
      pane: 'Account & devices',
      paths: {'/devices': _devices, '/auth/totp': _totp(on: false)},
    ),
    'sr-account-totp-on': (
      pane: 'Account & devices',
      paths: {'/devices': _devices, '/auth/totp': _totp(on: true)},
    ),
    'sr-blocked-empty': (pane: 'Blocked', paths: {'/blocks': <Object>[]}),
    'sr-blocked-list': (
      pane: 'Blocked',
      paths: {
        '/blocks': ['u-1', 'u-2'],
      },
    ),
    'sr-reports': (pane: 'Report status', paths: {}),
  };

  for (final theme in const [darkAndLight]) {
    for (final entry in surfaces.entries) {
      for (final viewport in const ['phone-portrait', 'desktop']) {
        testWidgets('${entry.key} at $viewport ($theme)', (tester) async {
          await renderSurface(
            tester,
            Routes.personalSettings,
            viewport,
            theme,
            '${entry.key}-$viewport-$theme',
            overrides: [
              apiProvider.overrideWith(
                (ref) => _apiWith(ref, entry.value.paths),
              ),
            ],
            settleNestedResolve: true,
            afterSettle: (tester) async {
              await tester.tap(find.text(entry.value.pane).first);
              await tester.pump(const Duration(milliseconds: 350));
              await tester.pump(const Duration(milliseconds: 350));
            },
          );
        });
      }
    }
  }
}
