// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AppAsyncView]: the three canonical states, and the fourth shape that
/// only shows up once a caller has both a real error and real data at the
/// same time - a refresh that fails after an earlier fetch already
/// succeeded, which Riverpod's own retained-previous-value behaviour makes
/// routine rather than rare.
///
/// Two of those stale-plus-error tests reproduce a real call site's own
/// layout shape rather than a synthetic one: an `Expanded` ancestor handing
/// down a bounded box with a `ListView` as the data widget (roles, removed
/// members, member role assignment), and the settings frame's own default
/// unbounded `ListView(children: [child])` (invites, emoji, analytics).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(height: 400, width: 300, child: child),
        ),
      ),
    );

void main() {
  testWidgets('a bare fetch failure with no prior data shows only the error', (
    tester,
  ) async {
    await _pump(
      tester,
      AppAsyncView<List<int>>(
        value: const AppAsyncState(error: 'boom'),
        data: (context, list) => Text('${list.length} items'),
        errorMessage: 'Could not load the list.',
      ),
    );

    expect(find.text('Could not load the list.'), findsOneWidget);
    expect(find.textContaining('items'), findsNothing);
  });

  testWidgets(
    'a refresh failure that still carries the last known data keeps '
    'showing that data alongside the error, rather than wiping it',
    (tester) async {
      var retried = false;
      await _pump(
        tester,
        AppAsyncView<List<int>>(
          value: const AppAsyncState(data: [1, 2, 3], error: 'boom'),
          data: (context, list) => Text('${list.length} items'),
          errorMessage: 'Could not load the list.',
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('Could not load the list.'), findsOneWidget);
      expect(find.text('3 items'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    },
  );

  testWidgets(
    'the same stale-plus-error shape works when data is a viewport that '
    'needs the bounded height an Expanded ancestor gives it',
    (tester) async {
      // See this file's own doc comment for what real shape this stands in for.
      await _pump(
        tester,
        Column(
          children: [
            Expanded(
              child: AppAsyncView<List<int>>(
                value: const AppAsyncState(data: [1, 2, 3], error: 'boom'),
                data: (context, list) => ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => Text('row ${list[i]}'),
                ),
                errorMessage: 'Could not load the list.',
              ),
            ),
          ],
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load the list.'), findsOneWidget);
      expect(find.text('row 1'), findsOneWidget);
    },
  );

  testWidgets(
    'the same stale-plus-error shape works inside the unbounded scrollable '
    'frame most settings screens use',
    (tester) async {
      // See this file's own doc comment for what real shape this stands in for.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ListView(
              children: [
                AppAsyncView<List<int>>(
                  value: const AppAsyncState(data: [1, 2, 3], error: 'boom'),
                  data: (context, list) => Column(
                    children: [
                      for (final n in list) Text('row $n'),
                    ],
                  ),
                  errorMessage: 'Could not load the list.',
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load the list.'), findsOneWidget);
      expect(find.text('row 1'), findsOneWidget);
    },
  );

  testWidgets('loading with nothing yet known shows the spinner, not blank', (
    tester,
  ) async {
    await _pump(
      tester,
      AppAsyncView<List<int>>(
        value: const AppAsyncState<List<int>>(),
        data: (context, list) => Text('${list.length} items'),
        errorMessage: 'Could not load the list.',
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Could not load the list.'), findsNothing);
  });

  testWidgets('an empty result is told apart from an error', (tester) async {
    await _pump(
      tester,
      AppAsyncView<List<int>>(
        value: const AppAsyncState(data: <int>[]),
        data: (context, list) => Text('${list.length} items'),
        errorMessage: 'Could not load the list.',
        isEmpty: (list) => list.isEmpty,
        emptyMessage: 'Nothing here yet.',
      ),
    );

    expect(find.text('Nothing here yet.'), findsOneWidget);
    expect(find.text('Could not load the list.'), findsNothing);
    expect(find.text('0 items'), findsNothing);
  });
}
