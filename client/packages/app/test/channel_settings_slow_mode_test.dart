// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Channel settings screen's slow-mode section: tapping a preset sends a
/// PATCH and the control reflects the saved value, the same round trip
/// `channel_settings_management_test.dart` covers for name and topic.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';

import 'channel_management_harness.dart';

void main() {
  testWidgets('choosing a preset sends a PATCH with slow_mode_seconds and '
      'the control reflects it', (tester) async {
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
        handler: (request) {
          requests.add(request);
          return request.method == 'PATCH'
              ? http.Response(
                  jsonEncode({
                    'id': 'c1',
                    'name': 'general',
                    'kind': 'text',
                    'created_at': 0,
                    'slow_mode_seconds': 30,
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                )
              : http.Response('{}', 200);
        },
      ),
    );

    await tester.tap(find.bySemanticsLabel('Manage general'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Channel settings...'));
    await tester.pumpAndSettle();

    expect(find.text('Slow mode'), findsOneWidget);
    expect(
      find.text('Off'),
      findsWidgets,
      reason: 'a fresh channel starts with slow mode off',
    );

    // One row in the General card now; its choices open in a sheet.
    await tester.tap(find.text('Slow mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30s'));
    await tester.pumpAndSettle();

    final patched = requests.where((r) => r.url.path == '/channels/c1');
    expect(patched, hasLength(1));
    expect(jsonDecode(patched.first.body) as Map<String, dynamic>, {
      'slow_mode_seconds': 30,
    });
    expect(
      find.text('30s'),
      findsOneWidget,
      reason: 'the row shows the choice',
    );
  });
}
