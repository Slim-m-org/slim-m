// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three ways into a context menu, driven the way a real input makes them.
/// A right-click is held past the press deadline, because only the up event
/// is winner-only (see `context_menu_region_nesting_test.dart`).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> rightClickMenu(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> longPressMenu(WidgetTester tester, Finder target) async {
  await tester.longPress(target);
  await tester.pumpAndSettle();
}

/// Tabs [tabs] times to reach the region's stop, then presses the menu key.
Future<void> keyboardMenu(WidgetTester tester, {int tabs = 1}) async {
  for (var i = 0; i < tabs; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
  await tester.pumpAndSettle();
}
