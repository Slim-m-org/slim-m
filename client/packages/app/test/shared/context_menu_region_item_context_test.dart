// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The context `ContextMenuRegion.itemsBuilder` hands its items used to be
/// the overlay's (wide) or the sheet's (compact). An item that called `close`
/// and then opened a popover from it - the call tile's Moderate... - opened
/// it against a box that no longer existed. It is now the region's own.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

const _child = Key('region-child');

Future<BuildContext?> _openActAndClose(
  WidgetTester tester, {
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  BuildContext? captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: ContextMenuRegion(
            itemsBuilder: (context, close) => [
              AppMenuItem(
                label: 'Act',
                onTap: () {
                  close();
                  captured = context;
                },
              ),
            ],
            // A bare SizedBox is invisible to hit-testing; paint it so the press lands.
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
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(_child)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.tap(find.text('Act'));
  await tester.pumpAndSettle();
  return captured;
}

void _expectAnchoredToChild(WidgetTester tester, BuildContext? captured) {
  expect(captured, isNotNull);
  expect(
    captured!.mounted,
    isTrue,
    reason: 'the items context must outlive close, or nothing can open from it',
  );
  final box = captured.findRenderObject()! as RenderBox;
  final origin = box.localToGlobal(Offset.zero);
  expect(
    origin & box.size,
    tester.getRect(find.byKey(_child)),
    reason: 'the items context anchors to the wrapped child, not the menu',
  );
}

void main() {
  testWidgets('wide: an item can act on its context after close', (
    tester,
  ) async {
    _expectAnchoredToChild(tester, await _openActAndClose(tester, width: 1200));
  });

  testWidgets('compact: the same holds when the menu was a sheet', (
    tester,
  ) async {
    _expectAnchoredToChild(tester, await _openActAndClose(tester, width: 500));
  });
}
