// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _panel = Key('menu-submenu-panel');
const _row = Key('row');
const _other = Key('other');
const _size = Size(600, 500);

Future<void> _pump(WidgetTester tester, Alignment alignment) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: AppMenu(
            width: 200,
            children: [
              AppSubmenuItem(
                key: _row,
                label: 'More',
                itemsBuilder: (_) => [
                  for (var i = 0; i < 6; i++)
                    AppMenuItem(label: 'Choice $i', onTap: () {}),
                ],
              ),
              AppMenuItem(key: _other, label: 'Other', onTap: () {}),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_row));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('opens to the right of the row and lines up with it', (
    tester,
  ) async {
    await _pump(tester, Alignment.centerLeft);
    final row = tester.getRect(find.byKey(_row));
    await _open(tester);

    final panel = tester.getRect(find.byKey(_panel));
    expect(panel.left, greaterThan(row.right));
    expect(panel.top, closeTo(row.top - 7, 0.5));
  });

  testWidgets('flips to the left at the right edge of the window', (
    tester,
  ) async {
    await _pump(tester, Alignment.centerRight);
    final row = tester.getRect(find.byKey(_row));
    await _open(tester);

    final panel = tester.getRect(find.byKey(_panel));
    expect(panel.right, lessThan(row.left));
    expect(panel.left, greaterThanOrEqualTo(0));
  });

  testWidgets('slides up to stay inside the window near the bottom', (
    tester,
  ) async {
    await _pump(tester, Alignment.bottomLeft);
    await _open(tester);

    final panel = tester.getRect(find.byKey(_panel));
    expect(panel.bottom, lessThanOrEqualTo(_size.height));
    expect(panel.top, greaterThanOrEqualTo(0));
  });

  testWidgets('moving onto another parent row closes the panel', (
    tester,
  ) async {
    await _pump(tester, Alignment.centerLeft);
    await _open(tester);
    expect(find.byKey(_panel), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.byKey(_other)));
    await tester.pump();

    expect(find.byKey(_panel), findsNothing);
  });

  testWidgets('Escape closes the panel and keeps the parent', (tester) async {
    await _pump(tester, Alignment.centerLeft);
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(_panel), findsNothing);
    expect(find.byKey(_row), findsOneWidget);
  });
}
