// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RailDragHandle] takes keyboard focus, so the hairline must show it: a
/// control Tab can land on with no visible change is a keyboard trap in all
/// but name.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/rail_drag_handle.dart';
import 'package:slimm_design_system/design_system.dart';

Color? _hairlineColor(WidgetTester tester) =>
    tester.widget<VerticalDivider>(find.byType(VerticalDivider)).color;

void main() {
  testWidgets('tabbing onto the handle paints the hairline in the focus ring', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: RailDragHandle()),
        ),
      ),
    );
    expect(_hairlineColor(tester), AppTokens.light.borderSubtle);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_hairlineColor(tester), AppTokens.light.focusRing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(_hairlineColor(tester), AppTokens.light.borderSubtle);
  });
}
