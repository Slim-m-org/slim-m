// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A handful of call sites reach for a raw `TextButton`/`FilledButton`/
/// `IconButton` instead of `AppButton`/`AppIconButton`, which draw
/// [AppTokens.focusRing] themselves. Without the theme-level fix this guards,
/// those raw widgets fell back to Material's own translucent focus overlay -
/// the exact inconsistency the rest of the system exists to avoid. See
/// `_focusRingSide`'s own doc comment in `app_theme.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

BorderSide? _resolvedSide(WidgetTester tester, Finder buttonFinder) {
  final material = tester.widget<Material>(
    find.descendant(of: buttonFinder, matching: find.byType(Material)).first,
  );
  final shape = material.shape;
  return shape is OutlinedBorder ? shape.side : null;
}

void main() {
  testWidgets('a focused FilledButton draws the focusRing border', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: FilledButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      ),
    );
    await tester.pump();

    final unfocused = _resolvedSide(tester, find.byType(FilledButton));
    expect(unfocused?.width ?? 0, 0);

    node.requestFocus();
    // A focus change needs a second pump before the resolved side updates.
    await tester.pump();
    await tester.pump();

    final focused = _resolvedSide(tester, find.byType(FilledButton));
    expect(focused?.color, AppTokens.dark.focusRing);
    expect(focused?.width, 2);
  });

  testWidgets('a focused TextButton draws the focusRing border', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: TextButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Retry'),
          ),
        ),
      ),
    );
    await tester.pump();
    node.requestFocus();
    // A focus change needs a second pump before the resolved side updates.
    await tester.pump();
    await tester.pump();

    final focused = _resolvedSide(tester, find.byType(TextButton));
    expect(focused?.color, AppTokens.light.focusRing);
    expect(focused?.width, 2);
  });

  testWidgets('a focused raw IconButton draws the focusRing border', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.trueBlack),
        home: Scaffold(
          body: IconButton(
            focusNode: node,
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    node.requestFocus();
    // A focus change needs a second pump before the resolved side updates.
    await tester.pump();
    await tester.pump();

    final focused = _resolvedSide(tester, find.byType(IconButton));
    expect(focused?.color, AppTokens.trueBlack.focusRing);
    expect(focused?.width, 2);
  });

  testWidgets('a focused raw IconButton draws the mocha focusRing border', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.mocha),
        home: Scaffold(
          body: IconButton(
            focusNode: node,
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    node.requestFocus();
    await tester.pump();
    await tester.pump();

    final focused = _resolvedSide(tester, find.byType(IconButton));
    expect(focused?.color, AppTokens.mocha.focusRing);
    expect(focused?.width, 2);
  });
}
