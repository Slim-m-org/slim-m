// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A floating context menu opened wide still closes after the window narrows.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> rightClick(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await g.up();
  await tester.pumpAndSettle();
}

Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: ContextMenuRegion(
          itemsBuilder: (context, close) => [
            AppMenuItem(label: 'Item one', onTap: close),
          ],
          child: const SizedBox(width: 120, height: 48, child: Text('row')),
        ),
      ),
    ),
  ),
);

void main() {
  for (final how in ['tap outside', 'escape']) {
    testWidgets('menu opened wide closes via $how after narrowing to compact', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpApp(tester);
      await rightClick(tester, tester.getCenter(find.text('row')));
      expect(find.text('Item one'), findsOneWidget, reason: 'opened');

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(
        find.text('Item one'),
        findsOneWidget,
        reason: 'still open after resize',
      );

      if (how == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tapAt(const Offset(300, 600));
      }
      await tester.pumpAndSettle();
      expect(find.text('Item one'), findsNothing, reason: 'menu must close');
    });
  }
}
