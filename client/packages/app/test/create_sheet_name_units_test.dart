// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A name is counted in unicode scalar values, as the server counts it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/create_category_sheet.dart';
import 'package:slimm_app/src/widgets/create_channel_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

// 40 astral code points: 80 UTF-16 units; the server's chars().count() is 40, within its 64 limit.
final name40 = String.fromCharCodes(List.filled(40, 0x1F600));

Future<void> open(WidgetTester tester, bool category) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'u',
            username: 'u',
            displayName: 'U',
            createdAt: 0,
            permissions: 0,
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => category
                  ? showCreateCategorySheet(context)
                  : showCreateChannelSheet(context, initialKind: 'text'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final category in [false, true]) {
    testWidgets('${category ? 'category' : 'channel'} sheet accepts 40 emoji', (
      tester,
    ) async {
      await open(tester, category);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is AppInput &&
              w.placeholder == (category ? 'Category name' : 'Channel name'),
        ),
        name40,
      );
      await tester.pump();
      expect(
        find.text('Name is too long'),
        findsNothing,
        reason: 'button label',
      );
      expect(find.text('40/64'), findsOneWidget, reason: 'counter');
      expect(find.text('Name is too long'), findsNothing);
    });
  }
}
