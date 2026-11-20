// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A closed menu's failure stays up until dismissed; its success times out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/widgets/menu_outcome.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/toast_host.dart';

Future<void> _pumpButton(
  WidgetTester tester,
  void Function(BuildContext) onPressed,
) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      builder: toastHost,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onPressed(context),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a failure is an error toast that outlives the toast timer', (
    tester,
  ) async {
    await _pumpButton(
      tester,
      (context) => showMenuOutcome(
        context,
        failure: 'Could not block them.',
        succeeded: 'Blocked.',
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump(ToastsController.defaultDuration * 2);

    expect(errorToasts(tester), ['Could not block them.']);
    expect(find.text('Could not block them.'), findsOneWidget);
  });

  testWidgets('a success is a confirmation that leaves on its timer', (
    tester,
  ) async {
    await _pumpButton(
      tester,
      (context) =>
          showMenuOutcome(context, failure: null, succeeded: 'Blocked.'),
    );
    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(toastMessages(tester), ['Blocked.']);
    expect(errorToasts(tester), isEmpty);
    await expireToasts(tester);
    expect(toastMessages(tester), isEmpty);
  });
}
