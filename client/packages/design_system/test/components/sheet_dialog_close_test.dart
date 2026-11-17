// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every sheet that opens with an [AppSheetHeader] closes the same way: a
/// close button on a desktop dialog, the handle and drag on a phone, and
/// Escape on both.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppSheet<void>(
              context,
              builder: (_) => const AppSheetHeader('Pinned messages'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a desktop dialog carries a close button that closes it', (
    tester,
  ) async {
    await _open(tester, const Size(1280, 800));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Pinned messages'), findsNothing);
  });

  testWidgets('Escape closes it too', (tester) async {
    await _open(tester, const Size(1280, 800));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Pinned messages'), findsNothing);
  });

  testWidgets('a phone sheet has no close button: the handle is its close', (
    tester,
  ) async {
    await _open(tester, const Size(390, 800));

    expect(find.byTooltip('Close'), findsNothing);
  });

  testWidgets('a header with its own trailing places the close button itself',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                builder: (_) => const AppSheetHeader(
                  'Inbox',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text('Mark all read'), AppSheetCloseButton()],
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Mark all read'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });
}
