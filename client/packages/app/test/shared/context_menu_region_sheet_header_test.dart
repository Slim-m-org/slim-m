// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A region's sheet header names what a compact sheet acts on; the anchored
/// menu beside the pointer stays untitled.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

const _child = Key('region-child');

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: ContextMenuRegion(
            itemsBuilder: (context, close) => [
              AppMenuItem(label: 'Edit a copy', onTap: close),
            ],
            sheetHeaderBuilder: (context) =>
                const AppSheetHeader('Midnight', caption: 'Space · by Kai'),
            child: Container(
              key: _child,
              width: 120,
              height: 40,
              color: Colors.grey,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a long press on a phone opens a titled sheet', (tester) async {
    await _pump(tester, 390);

    await tester.longPress(find.byKey(_child));
    await _settle(tester);

    expect(find.text('Edit a copy'), findsOneWidget);
    expect(find.text('Midnight'), findsOneWidget);
    expect(find.text('Space · by Kai'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Space · by Kai')).dy,
      lessThan(tester.getTopLeft(find.text('Edit a copy')).dy),
    );
  });

  testWidgets('a right-click on a wide window opens the menu untitled', (
    tester,
  ) async {
    await _pump(tester, 1280);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_child)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    await gesture.up();
    await _settle(tester);

    expect(find.text('Edit a copy'), findsOneWidget);
    expect(find.text('Midnight'), findsNothing);
  });
}
