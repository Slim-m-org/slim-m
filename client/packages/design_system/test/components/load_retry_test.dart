// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed load retries on its own: on a backoff while on screen, at once when
/// the app comes back, and never once it is gone, hidden or cannot be retried.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester,
  VoidCallback? onRetry, {
  AppAsyncState<int> value = const AppAsyncState(error: 'boom'),
  Widget Function(Widget view) around = _bare,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: around(
            AppAsyncView<int>(
              value: value,
              data: (context, _) => const SizedBox(),
              errorMessage: 'Could not load the list.',
              onRetry: onRetry,
            ),
          ),
        ),
      ),
    );

Widget _bare(Widget view) => view;

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

  testWidgets('a retry that shows the spinner keeps its place in the backoff', (
    tester,
  ) async {
    var retries = 0;
    void retry() => retries++;
    await _pump(tester, retry);

    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 1);
    await _pump(tester, retry, value: const AppAsyncState());
    await _pump(tester, retry);

    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 1, reason: 'the second wait is the second delay');
    await tester.pump(appLoadRetryDelays[1] - appLoadRetryDelays[0]);
    expect(retries, 2);
  });

  testWidgets(
      'a load that succeeds starts the next failure from the first wait', (
    tester,
  ) async {
    var retries = 0;
    void retry() => retries++;
    await _pump(tester, retry);
    await tester.pump(appLoadRetryDelays[0]);
    await _pump(tester, retry, value: const AppAsyncState(data: 1));
    await _pump(tester, retry);

    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 2);
  });

  testWidgets('a view whose tickers are off waits until it is back', (
    tester,
  ) async {
    var retries = 0;
    void retry() => retries++;
    Widget Function(Widget) ticking(bool on) =>
        (view) => TickerMode(enabled: on, child: view);
    await _pump(tester, retry, around: ticking(false));

    await tester.pump(appLoadRetryDelays.last * 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(retries, 0);

    await _pump(tester, retry, around: ticking(true));
    await tester.pump(appLoadRetryDelays[0]);
    expect(retries, 1);
  });

  testWidgets('a tab of an IndexedStack that is not showing waits', (
    tester,
  ) async {
    var retries = 0;
    Widget tabs(Widget view) =>
        IndexedStack(index: 0, children: [const SizedBox(), view]);
    await _pump(tester, () => retries++, around: tabs);

    await tester.pump(appLoadRetryDelays.last * 3);
    expect(retries, 0);
  });

  testWidgets('a failure the policy refuses is neither retried nor offered', (
    tester,
  ) async {
    var retries = 0;
    Widget policy(Widget view) =>
        AppLoadRetryPolicy(retries: (error) => error != 'boom', child: view);
    await _pump(tester, () => retries++, around: policy);

    await tester.pump(appLoadRetryDelays.last * 3);
    expect(retries, 0);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Could not load the list.'), findsOneWidget);
  });
}
