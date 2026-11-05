// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives the Modules list's overflow menu and segments, and a module page's folds.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _settle = Duration(milliseconds: 400);

/// Opens the Modules overflow menu and taps [item] in it.
Future<void> tapDockMenuItem(WidgetTester tester, String item) async {
  await tester.tap(find.bySemanticsLabel('Module options'));
  await tester.pump(_settle);
  await tester.tap(find.text(item));
  await tester.pump(_settle);
  await tester.pump(_settle);
}

/// Switches the Modules list to its Installed or Browse segment.
Future<void> openDockTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab));
  for (var i = 0; i < 4; i++) {
    await tester.pump(_settle);
  }
}

/// Opens a module page's folded [fold]: `roles` (who can use it) or `details`.
///
/// A module not yet installed shows its details unfolded, so there is nothing to open.
Future<void> openDockFold(WidgetTester tester, String fold) async {
  final toggle = find.byKey(Key('dock-$fold-toggle'));
  if (toggle.evaluate().isEmpty) return;
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  for (var i = 0; i < 2; i++) {
    await tester.pump(_settle);
  }
}

/// Presses the pinned Install, which on a first install opens the sheet asking what the module may do.
Future<void> openInstallAccess(WidgetTester tester) async {
  final install = find.textContaining(RegExp(r'^Install v'));
  await tester.ensureVisible(install);
  await tester.tap(install);
  for (var i = 0; i < 3; i++) {
    await tester.pump(_settle);
  }
}

/// Confirms the install access sheet with whatever its switches show.
Future<void> confirmInstallAccess(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('dock-install-access-confirm')));
  for (var i = 0; i < 3; i++) {
    await tester.pump(_settle);
  }
}
