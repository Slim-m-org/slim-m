// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed load retries on its own: on a backoff while shown, at once when
/// the app comes back, and never once it is gone or cannot be retried.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, VoidCallback? onRetry) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppAsyncView<int>(
            value: const AppAsyncState(error: 'boom'),
            data: (context, _) => const SizedBox(),
            errorMessage: 'Could not load the list.',
            onRetry: onRetry,
          ),
        ),
      ),
    );

void main() {
  testWidgets('a failed load retries on a widening backoff', (tester) async {
    var retries = 0;
    await _pump(tester, () => retries++);

    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 1);
    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 1, reason: 'the second wait is longer than the first');
    await tester.pump(appLoadRetryDelays[1] - appLoadRetryDelays[0]);
    expect(retries, 2);
    for (var i = 0; i < 5; i++) {
      await tester.pump(appLoadRetryDelays.last);
    }
    expect(retries, greaterThanOrEqualTo(6), reason: 'it keeps trying');
  });

  testWidgets('coming back to the app retries at once', (tester) async {
    var retries = 0;
    await _pump(tester, () => retries++);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(retries, 1);
  });

  testWidgets('a failure that cannot be retried waits for nobody', (
    tester,
  ) async {
    await _pump(tester, null);
    await tester.pump(appLoadRetryDelays.last * 3);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a recovered load stops retrying', (tester) async {
    var retries = 0;
    await _pump(tester, () => retries++);
    await tester.pumpWidget(const SizedBox());

    await tester.pump(appLoadRetryDelays.last * 3);
    expect(retries, 0);
  });
}
