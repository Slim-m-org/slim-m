// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives the Modules list's overflow menu and a module page's tabs.
library;

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

/// Switches a module page to its [tab] (Overview, Access or Settings), or the
/// Modules list to its Installed or Browse segment.
Future<void> openDockTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab));
  for (var i = 0; i < 4; i++) {
    await tester.pump(_settle);
  }
}
