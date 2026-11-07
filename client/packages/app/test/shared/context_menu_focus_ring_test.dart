// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row ring marks the row's own keyboard focus, never a control inside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_focus.dart';
import 'package:slimm_design_system/design_system.dart';

bool _ringShown(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('row')),
        matching: find.bySubtype<DecoratedBox>(),
      ),
    )
    .any((box) => (box.decoration as BoxDecoration).border != null);

void main() {
  testWidgets('a focused control inside the row does not ring the row', (
    tester,
  ) async {
    final rowNode = FocusNode();
    final inner = FocusNode();
    addTearDown(rowNode.dispose);
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ContextMenuFocus(
            key: const Key('row'),
            focusNode: rowNode,
            onOpen: () {},
            child: Focus(focusNode: inner, child: const SizedBox(height: 40)),
          ),
        ),
      ),
    );
    // Keyboard highlight mode, as after the arrow keys an app's grid takes.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    inner.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(_ringShown(tester), isFalse);

    rowNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(_ringShown(tester), isTrue);
  });
}
