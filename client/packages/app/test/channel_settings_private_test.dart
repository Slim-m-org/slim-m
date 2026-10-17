// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Making an existing channel private from its settings: confirmed first,
/// then `@everyone` loses the view and you keep it, with every other bit both
/// overwrites already held left alone. Turning it off lifts only that deny.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_private_row.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';

import 'channel_management_harness.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<List<http.Request>> _open(
  WidgetTester tester, {
  required List<Map<String, Object>> overwrites,
}) async {
  final requests = <http.Request>[];
  await tester.pumpWidget(
    harness(
      ChannelCategorySections(
        channels: [channel('c1', 'general')],
        categories: const [],
        selectedId: null,
        canManage: true,
        onReorder: (_) {},
      ),
      permissions: Perm.manageChannels | Perm.manageRoles,
      handler: (request) {
        requests.add(request);
        final path = request.url.path;
        if (path == '/roles') {
          return _json([
            {
              'id': 'everyone',
              'name': 'everyone',
              'permissions': Perm.viewChannel | Perm.sendMessages,
              'is_everyone': true,
              'created_at': 0,
            },
          ]);
        }
        if (path == '/channels/c1/overwrites') {
          return _json({'overwrites': overwrites, 'synced': false});
        }
        return http.Response('{}', 200);
      },
    ),
  );
  await tester.tap(find.bySemanticsLabel('Manage general'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Channel settings...'));
  await tester.pumpAndSettle();
  return requests;
}

Map<String, Map<String, dynamic>> _written(List<http.Request> requests) {
  final put = requests.lastWhere(
    (r) => r.method == 'PUT' && r.url.path == '/channels/c1/overwrites',
  );
  final body = jsonDecode(put.body) as Map<String, dynamic>;
  return {
    for (final o in (body['overwrites'] as List).cast<Map<String, dynamic>>())
      '${o['kind']}:${o['id']}': o,
  };
}

void main() {
  testWidgets('turning Private on asks, then hides it from everyone but you', (
    tester,
  ) async {
    final requests = await _open(
      tester,
      overwrites: [
        {
          'kind': 'role',
          'id': 'everyone',
          'allow': Perm.viewChannel,
          'deny': Perm.sendMessages,
        },
      ],
    );

    await tester.tap(find.bySemanticsLabel('Private channel'));
    await tester.pumpAndSettle();
    expect(find.text('Make #general private?'), findsOneWidget);
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();

    final written = _written(requests);
    expect(written['role:everyone'], {
      'kind': 'role',
      'id': 'everyone',
      'allow': 0,
      'deny': Perm.sendMessages | Perm.viewChannel,
    });
    expect(written['member:user-1']?['allow'], Perm.viewChannel);
  });

  testWidgets('cancelling the question changes nothing', (tester) async {
    final requests = await _open(tester, overwrites: const []);

    await tester.tap(find.bySemanticsLabel('Private channel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('making it public lifts only the view deny', () async {
    final puts = <Map<String, dynamic>>[];
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: api.SessionStore(tokens: tokens),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT') {
          puts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json({'overwrites': <Object>[], 'synced': false});
        }
        return _json({
          'overwrites': [
            {
              'kind': 'role',
              'id': 'everyone',
              'allow': 0,
              'deny': Perm.viewChannel | Perm.sendMessages,
            },
          ],
          'synced': false,
        });
      }),
    );
    addTearDown(client.close);

    await makeChannelPublic(
      client,
      channelId: 'c1',
      everyoneRoleId: 'everyone',
    );

    expect(puts.single['overwrites'], [
      {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.sendMessages},
    ]);
  });
}
