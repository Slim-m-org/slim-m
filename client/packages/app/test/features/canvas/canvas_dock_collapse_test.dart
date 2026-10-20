// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen dock handle: a pass-through outside fullscreen, and a
/// folded dock that is out of reach as well as out of sight.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_dock_collapse.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host({required bool collapsible}) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: CanvasDockCollapse(
        collapsible: collapsible,
        builder: (_, __) => const SizedBox(
          height: 48,
          width: 200,
          child: TextField(key: Key('dock-field')),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('outside fullscreen it is a pass-through with no handle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(collapsible: false));
    expect(find.byKey(const Key('dock-field')).hitTestable(), findsOneWidget);
    expect(find.byTooltip('Show controls'), findsNothing);
    expect(find.byTooltip('Hide controls'), findsNothing);
  });

  testWidgets('folded, the dock takes no height and cannot be hit, and '
      'unfolding gives it back', (tester) async {
    await tester.pumpWidget(_host(collapsible: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dock-field')).hitTestable(), findsNothing);
    expect(
      tester.getSize(find.byType(CanvasDockCollapse)).height,
      lessThan(canvasDockRevealZone + 1),
    );
    expect(find.byTooltip('Show controls'), findsOneWidget);

    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dock-field')).hitTestable(), findsOneWidget);
    expect(find.byTooltip('Hide controls'), findsOneWidget);
  });

  testWidgets('returning to non-fullscreen unfolds a pinned dock', (
    tester,
  ) async {
    await tester.pumpWidget(_host(collapsible: true));
    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(collapsible: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dock-field')).hitTestable(), findsOneWidget);

    await tester.pumpWidget(_host(collapsible: true));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('dock-field')).hitTestable(),
      findsNothing,
      reason: 'a new fullscreen starts folded, not pinned open by the last one',
    );
  });
}
