// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A session the server ended says so on the sign-in screen; one the person
/// ended themselves says nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_session_ended_notice.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, api.SessionStore session) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: SessionEndedNotice()),
        ),
      ),
    );

void main() {
  testWidgets('a refresh the server rejected explains the sign-out', (
    tester,
  ) async {
    final session = api.SessionStore()
      ..clear(reason: 'credentials rejected; the stored pair was spent');
    await _pump(tester, session);
    expect(find.textContaining('signed out from another device'), findsOne);
  });

  testWidgets('Sign Out by the person says nothing', (tester) async {
    final session = api.SessionStore()..clear();
    await _pump(tester, session);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a session that never ended says nothing', (tester) async {
    await _pump(tester, api.SessionStore());
    expect(find.byType(Text), findsNothing);
  });
}
