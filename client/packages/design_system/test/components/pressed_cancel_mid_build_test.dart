// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A control disabled while a finger is down loses its tap recognizer in the
/// build phase, which cancels the press; none of the four may setState there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

typedef _Build = Widget Function(bool enabled);

final _controls = <String, _Build>{
  'AppButton': (on) => AppButton(label: 'Save', onPressed: on ? () {} : null),
  'AppIconButton': (on) => AppIconButton(
        icon: AppIcons.settings,
        semanticLabel: 'Settings',
        onPressed: on ? () {} : null,
      ),
  'AppMenuItem': (on) =>
      AppMenuItem(label: 'Copy link', onTap: on ? () {} : null),
  'AppListRow': (on) => AppListRow(label: 'general', onTap: on ? () {} : null),
};

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Center(child: SizedBox(width: 240, child: child))),
    ),
  );
}

void main() {
  for (final entry in _controls.entries) {
    testWidgets('${entry.key} disabled mid-press does not setState in build', (
      tester,
    ) async {
      await _pump(tester, entry.value(true));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(entry.value(true).runtimeType)),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await _pump(tester, entry.value(false));
      await tester.pump();

      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
