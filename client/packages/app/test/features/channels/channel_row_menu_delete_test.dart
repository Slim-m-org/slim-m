// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A manager deletes a channel straight from its row menu, without going
/// through Channel settings; the owner found no way to do it from the sheet.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';

import 'channel_management_harness.dart';
import '../../support/menu_gestures.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('a manager deletes the open channel from its row menu', (
    tester,
  ) async {
    final requests = <http.Request>[];
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general'), channel('c2', 'random')],
          categories: const [],
          selectedId: 'c1',
          canManage: true,
          onReorder: (_) {},
        ),
        initialLocation: Routes.channel('c1'),
        handler: (request) {
          requests.add(request);
          return request.method == 'DELETE'
              ? http.Response('', 204)
              : http.Response('{}', 200);
        },
      ),
    );
    await _settle(tester);

    await clickHoverRevealed(tester, find.bySemanticsLabel('Manage general'));
    await _settle(tester);
    await tester.tap(find.text('Delete channel...'));
    await _settle(tester);
    expect(find.text('Delete "general"?'), findsOneWidget);
    await tester.tap(find.text('Delete permanently'));
    await _settle(tester);

    expect(requests.where((r) => r.method == 'DELETE').map((r) => r.url.path), [
      '/channels/c1',
    ]);
    expect(
      find.text('channel:c1'),
      findsNothing,
      reason: 'the pane must leave a channel that no longer exists',
    );
  });

  testWidgets('keeping the channel deletes nothing', (tester) async {
    final requests = <http.Request>[];
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general'), channel('c2', 'random')],
          categories: const [],
          selectedId: null,
          canManage: true,
          onReorder: (_) {},
        ),
        handler: (request) {
          requests.add(request);
          return http.Response('{}', 200);
        },
      ),
    );
    await _settle(tester);

    await clickHoverRevealed(tester, find.bySemanticsLabel('Manage general'));
    await _settle(tester);
    await tester.tap(find.text('Delete channel...'));
    await _settle(tester);
    await tester.tap(find.text('Keep channel'));
    await _settle(tester);

    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
  });

  testWidgets('without manage rights there is no delete entry', (tester) async {
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general'), channel('c2', 'random')],
          categories: const [],
          selectedId: null,
          canManage: false,
          onReorder: (_) {},
        ),
        handler: (_) => http.Response('{}', 200),
      ),
    );
    await _settle(tester);

    // A plain member's row has no kebab; the right-click is the same menu.
    await tester.tapAt(
      tester.getCenter(find.text('general')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await _settle(tester);

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Delete channel...'), findsNothing);
  });
}
