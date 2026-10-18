// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel's own message retention in its settings: shown to someone who
/// manages the Space, following the Space until changed, and asking with a
/// count before a shorter window deletes anything.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';

import 'channel_management_harness.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<List<http.Request>> _open(
  WidgetTester tester, {
  required int perms,
}) async {
  final requests = <http.Request>[];
  int? own;
  await tester.pumpWidget(
    harness(
      ChannelCategorySections(
        channels: [channel('c1', 'jellyfin')],
        categories: const [],
        selectedId: null,
        canManage: true,
        onReorder: (_) {},
      ),
      permissions: perms,
      handler: (request) {
        requests.add(request);
        final path = request.url.path;
        if (path == '/channels/c1/retention/preview') {
          return _json({'retention_days': 30, 'messages': 412});
        }
        if (path == '/channels/c1/retention') {
          if (request.method == 'PUT') {
            own = (jsonDecode(request.body) as Map)['retention_days'] as int?;
          }
          return _json({'retention_days': own, 'space_retention_days': 0});
        }
        return http.Response('{}', 200);
      },
    ),
  );
  await tester.tap(find.bySemanticsLabel('Manage jellyfin'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Channel settings...'));
  await tester.pumpAndSettle();
  return requests;
}

void main() {
  testWidgets('a shorter window counts what goes and asks first', (
    tester,
  ) async {
    final requests = await _open(
      tester,
      perms: Perm.manageChannels | Perm.manageServer,
    );
    expect(find.text('Space default (Keep forever)'), findsOneWidget);

    await tester.ensureVisible(find.text('Message retention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message retention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(find.text('Delete messages older than 30 days?'), findsOneWidget);
    expect(find.textContaining('412 messages'), findsOneWidget);
    await tester.tap(find.text('Delete old messages'));
    await tester.pumpAndSettle();

    final put = requests.where((r) => r.method == 'PUT').single;
    expect(jsonDecode(put.body), {'retention_days': 30});
    expect(find.text('30 days'), findsOneWidget);
  });

  testWidgets('backing out of the question saves nothing', (tester) async {
    final requests = await _open(
      tester,
      perms: Perm.manageChannels | Perm.manageServer,
    );
    await tester.ensureVisible(find.text('Message retention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message retention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.method == 'PUT'), isEmpty);
    expect(find.text('Space default (Keep forever)'), findsOneWidget);
  });

  testWidgets('without Manage Space settings the row is absent', (
    tester,
  ) async {
    await _open(tester, perms: Perm.manageChannels);

    expect(find.text('Message retention'), findsNothing);
  });
}
