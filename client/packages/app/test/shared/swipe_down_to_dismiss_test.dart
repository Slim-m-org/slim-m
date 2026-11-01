// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SwipeDownToDismiss] against a plain child - no real video, no native
/// texture - so the drag-to-dismiss gesture itself is exercised without any
/// of the `media_kit` fragility that makes mounting a real `Video` widget
/// repeatedly in one test process slow and occasionally hang on teardown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/swipe_down_to_dismiss.dart';

Widget _harness({required bool enabled, required VoidCallback onDismiss}) {
  return MaterialApp(
    home: Scaffold(
      body: SwipeDownToDismiss(
        enabled: enabled,
        onDismiss: onDismiss,
        // A bare ColoredBox under Scaffold's loose constraints lays out at zero size.
        child: const SizedBox.expand(child: ColoredBox(color: Colors.black)),
      ),
    ),
  );
}

Finder _ownTransform() => find.descendant(
  of: find.byType(SwipeDownToDismiss),
  matching: find.byType(Transform),
);

void main() {
  testWidgets('a swipe past the threshold dismisses', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      _harness(enabled: true, onDismiss: () => dismissed++),
    );

    await tester.drag(find.byType(SwipeDownToDismiss), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(dismissed, 1);
  });

  testWidgets('a short drag snaps back instead of dismissing', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      _harness(enabled: true, onDismiss: () => dismissed++),
    );

    await tester.drag(find.byType(SwipeDownToDismiss), const Offset(0, 20));
    await tester.pumpAndSettle();

    expect(dismissed, 0);
    final translate = tester.widget<Transform>(_ownTransform());
    expect(translate.transform.getTranslation().y, 0);
  });

  testWidgets('a disabled swipe does nothing at all', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      _harness(enabled: false, onDismiss: () => dismissed++),
    );

    await tester.drag(find.byType(SwipeDownToDismiss), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(dismissed, 0);
  });
}
