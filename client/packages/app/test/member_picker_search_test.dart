// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member picker sheet filters its list by display name or username, so
/// one person is findable without scrolling every member.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/screens/admin/overwrite_target_picker_sheets.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester) async {
  final members = [
    for (var i = 0; i < 300; i++)
      api.UserProfile(
        id: 'u$i',
        username: 'user$i',
        displayName: 'Member $i',
        createdAt: 0,
      ),
    const api.UserProfile(
      id: 'ada',
      username: 'lovelace',
      displayName: 'Ada',
      createdAt: 0,
    ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [membersProvider.overrideWith((ref) async => members)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: MemberPickerSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing narrows the list by display name', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'ada');
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Member 1'), findsNothing);
  });

  testWidgets('typing also matches the username', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'lovelace');
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('a filter that matches nobody says so', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();

    expect(find.text('No members match.'), findsOneWidget);
  });
}
