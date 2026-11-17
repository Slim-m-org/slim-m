// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category header's actions are reachable from a visible kebab, not only a
/// right-click, the way a channel row's are.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _rail({required bool canManage}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: ChannelCategorySections(
        channels: const [],
        categories: const [
          ChannelCategoryRow(id: 'dev', name: 'dev', position: 0),
        ],
        selectedId: null,
        canManage: canManage,
        onReorder: (_) {},
      ),
    ),
  ),
);

Finder get _kebab => find.bySemanticsLabel('Manage dev');

void main() {
  testWidgets('a manager opens the category menu from the header kebab', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(canManage: true));
    await tester.pump();

    await tester.tap(_kebab);
    await tester.pumpAndSettle();

    expect(find.text('Rename category...'), findsOneWidget);
    expect(find.text('Delete category...'), findsOneWidget);
  });

  testWidgets('somebody who cannot manage categories gets no kebab', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(canManage: false));
    await tester.pump();

    expect(_kebab, findsNothing);
  });
}
