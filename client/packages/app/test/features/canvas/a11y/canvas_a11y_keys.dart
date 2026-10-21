// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Driving and reading keyboard focus in the canvas accessibility probe: Tab
/// stops by name, arrow keys inside menus, and the keyboard route into the
/// overflow menu.
///
/// Not a `_test.dart` file, so `flutter test` does not run it.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_a11y_rig.dart';

/// The accessible name of whatever holds keyboard focus, or a note on why it has none.
String focusedName(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return '(no focus)';
  SemanticsNode? node;
  for (
    RenderObject? r = context.findRenderObject();
    r != null && node == null;
    r = r.parent
  ) {
    node = r.debugSemantics;
  }
  if (node == null) return '(focus on ${context.widget.runtimeType}, no node)';
  final data = node.getSemanticsData();
  final name = [
    data.label,
    data.tooltip,
  ].where((s) => s.isNotEmpty).join(' | ');
  return name.isEmpty ? '(unnamed ${context.widget.runtimeType})' : name;
}

/// The global rect of whatever holds keyboard focus.
Rect? focusedRect() {
  final render = FocusManager.instance.primaryFocus?.context
      ?.findRenderObject();
  if (render is! RenderBox || !render.attached) return null;
  return render.localToGlobal(Offset.zero) & render.size;
}

/// Whether keyboard focus sits in the route that is on top.
bool focusIsInTopRoute() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return ModalRoute.of(context)?.isCurrent ?? false;
}

Future<void> pressKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool control = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump(const Duration(milliseconds: 50));
}

/// Presses Tab [presses] times and returns the accessible name at each stop.
Future<List<String>> tabThrough(WidgetTester tester, int presses) async {
  final names = <String>[];
  for (var i = 0; i < presses; i++) {
    await pressKey(tester, LogicalKeyboardKey.tab);
    names.add(focusedName(tester));
  }
  return names;
}

/// Tabs until the focused name contains [name]; false when it never does.
Future<bool> tabTo(WidgetTester tester, Pattern name, {int limit = 80}) async {
  for (var i = 0; i < limit; i++) {
    if (focusedName(tester).contains(name)) return true;
    await pressKey(tester, LogicalKeyboardKey.tab);
  }
  return focusedName(tester).contains(name);
}

/// Moves keyboard focus with the arrow keys until the focused name starts with [name].
Future<bool> arrowTo(WidgetTester tester, String name, {int limit = 20}) async {
  for (var i = 0; i < limit; i++) {
    if (focusedName(tester).startsWith(name)) return true;
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
  }
  return focusedName(tester).startsWith(name);
}

/// Opens the dock's overflow menu with the keyboard alone.
Future<void> openOverflowByKeyboard(WidgetTester tester) async {
  expect(await tabTo(tester, 'More canvas actions'), isTrue);
  await pressKey(tester, LogicalKeyboardKey.enter);
  await settle(tester);
}

/// Opens the overflow menu with the keyboard and runs [item] from it.
Future<void> runOverflowItem(WidgetTester tester, String item) async {
  await openOverflowByKeyboard(tester);
  await pressKey(tester, LogicalKeyboardKey.arrowDown);
  expect(await arrowTo(tester, item), isTrue, reason: item);
  await pressKey(tester, LogicalKeyboardKey.enter);
  await settle(tester);
}
