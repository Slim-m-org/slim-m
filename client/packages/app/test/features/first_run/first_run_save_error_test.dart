// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed save says what happened and offers a way on: retry or skip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'first_run_harness.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settle(tester);
}

void main() {
  var failing = true;
  http.Response? refuse(http.Request r) {
    if (r.method == 'PUT' && r.url.path == '/push/preference' && failing) {
      return http.Response('{"error":"boom"}', 500);
    }
    return null;
  }

  setUp(() => failing = true);

  Future<FirstRunRig> toFailure(WidgetTester tester) async {
    final rig = await pumpFirstRun(tester, respond: refuse);
    await _tap(tester, 'Continue');
    await _tap(tester, 'Continue');
    await _tap(tester, 'Nothing');
    await _tap(tester, 'Continue');
    return rig;
  }

  testWidgets('says what failed and what to do, and stays on the step', (
    tester,
  ) async {
    await toFailure(tester);
    expect(find.textContaining('Could not save your choices'), findsOneWidget);
    expect(find.textContaining('Try again, or skip'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(find.text('Choose your notifications'), findsOneWidget);
  });

  testWidgets('retry saves again and moves on once it works', (tester) async {
    final rig = await toFailure(tester);
    failing = false;
    await _tap(tester, 'Retry');

    expect(rig.sent('PUT', '/push/preference'), hasLength(2));
    expect(find.text('Check your voice'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('skip for now moves on without saving again', (tester) async {
    final rig = await toFailure(tester);
    await _tap(tester, 'Skip for now');

    expect(rig.sent('PUT', '/push/preference'), hasLength(1));
    expect(find.text('Check your voice'), findsOneWidget);
    expect(find.text('Skip for now'), findsNothing);
  });
}
