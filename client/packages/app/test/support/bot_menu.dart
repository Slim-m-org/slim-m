// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reaching a bot's actions the way a person does: the kebab on its row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

/// Taps the kebab of the [index]th bot row and lets the menu (or sheet) open.
Future<void> openBotMenu(WidgetTester tester, {int index = 0}) async {
  await tester.tap(find.byIcon(AppIcons.moreVertical).at(index));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// A row in the open menu, found by its label.
Finder botMenuItem(String label) => find.widgetWithText(AppMenuItem, label);
