// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every option on the channel settings General card sends the right request,
/// and the ones behind MANAGE_ROLES stay hidden without it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/channels/channel_management_harness.dart';

const _json = {'content-type': 'application/json'};

Future<List<http.Request>> _open(
  WidgetTester tester, {
  int permissions = Perm.manageChannels,
  String kind = 'text',
  int slowMode = 0,
}) async {
  tester.view.physicalSize = const Size(800, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final requests = <http.Request>[];
  await tester.pumpWidget(
    harness(
      SingleChildScrollView(
        child: ChannelSettingsPane(
          channel: channel(
            'c1',
            'general',
            kind: kind,
          ).copyWith(slowModeSeconds: slowMode),
          wasOpen: false,
        ),
      ),
      permissions: permissions,
      handler: (request) {
        requests.add(request);
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'c1',
              'name': 'general',
              'kind': kind,
              'created_at': 0,
              'slow_mode_seconds': body['slow_mode_seconds'] ?? 0,
            }),
            200,
            headers: _json,
          );
        }
        if (request.url.path.contains('/voice')) {
          return http.Response('{"participants": []}', 200);
        }
        if (request.url.path.endsWith('/overwrites')) {
          return http.Response('{"overwrites": []}', 200, headers: _json);
        }
        return http.Response('[]', 200, headers: _json);
      },
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

List<Map<String, dynamic>> _patches(List<http.Request> requests) => [
  for (final r in requests.where((r) => r.method == 'PATCH'))
    jsonDecode(r.body) as Map<String, dynamic>,
];

void main() {
  const options = {'10s': 10, '30s': 30, '1m': 60, '10m': 600};
  for (final entry in options.entries) {
    testWidgets('slow mode ${entry.key} sends ${entry.value} seconds', (
      tester,
    ) async {
      final requests = await _open(tester);
      await tester.tap(find.text('Slow mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(_patches(requests), [
        {'slow_mode_seconds': entry.value},
      ]);
    });
  }

  testWidgets('slow mode Off sends 0 seconds', (tester) async {
    final requests = await _open(tester, slowMode: 30);
    await tester.tap(find.text('Slow mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();

    expect(_patches(requests), [
      {'slow_mode_seconds': 0},
    ]);
  });

  testWidgets('the slow mode row names what it does', (tester) async {
    await _open(tester);

    expect(
      tester
          .widget<SettingsSelectRow<int>>(find.byType(SettingsSelectRow<int>))
          .description,
      contains('between their own messages'),
    );
  });

  testWidgets('Private needs MANAGE_ROLES and is absent without it', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('Private'), findsNothing);
  });

  testWidgets('Private is offered with MANAGE_ROLES and asks to confirm', (
    tester,
  ) async {
    final requests = await _open(
      tester,
      permissions: Perm.manageChannels | Perm.manageRoles,
    );

    expect(find.text('Private'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == 'Private channel',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Make #general private?'), findsOneWidget);
    expect(_patches(requests), isEmpty);
  });

  testWidgets('without MANAGE_CHANNELS the General card and delete are gone', (
    tester,
  ) async {
    await _open(tester, permissions: Perm.manageRoles);

    expect(find.text('General'), findsNothing);
    expect(find.text('Slow mode'), findsNothing);
    expect(find.text('Delete channel...'), findsNothing);
  });
}
