// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rail section with nothing in it says so under its header, rather than
/// leaving a bare heading or a chevron with nothing to fold.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show presenceSeedProvider;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_management_harness.dart';

void main() {
  testWidgets('no direct messages says so under its header', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [presenceSeedProvider.overrideWith((ref, _) async {})],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: DirectMessagesSection(channels: [], selectedId: null),
          ),
        ),
      ),
    );

    expect(find.text('Direct messages'), findsOneWidget);
    expect(find.text('No direct messages yet.'), findsOneWidget);
  });

  testWidgets('a manager sees an empty category as one with no channels yet', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        ChannelCategorySections(
          channels: [channel('c1', 'general', categoryId: 'cat-1')],
          categories: const [
            ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
            ChannelCategoryRow(id: 'cat-2', name: 'Staff', position: 1),
            ChannelCategoryRow(
              id: 'cat-3',
              name: 'Archive',
              position: 2,
              parentId: 'cat-2',
            ),
          ],
          selectedId: null,
          canManage: true,
          onReorder: (_) {},
        ),
        handler: (_) => http.Response('{}', 200),
      ),
    );

    expect(find.text('No channels yet.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('No channels yet.')).dy,
      greaterThan(tester.getTopLeft(find.text('Archive')).dy),
    );
  });
}
