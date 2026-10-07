// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one stat tile the admin screens share: fixed width, danger-colored
/// value when it warns, and a loading skeleton the same width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/admin/admin_stat_tile.dart';
import 'package:slimm_app/src/screens/admin/analytics_ghost.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: Center(child: child)),
  ),
);

Color? _valueColor(WidgetTester tester, String value) =>
    tester.widget<Text>(find.text(value)).style?.color;

void main() {
  testWidgets('the tile is the shared width and shows value above label', (
    tester,
  ) async {
    await _pump(tester, const AdminStatTile(label: 'Members', value: '42'));

    expect(
      tester.getSize(find.byType(AdminStatTile)).width,
      adminStatTileWidth,
    );
    expect(
      tester.getTopLeft(find.text('42')).dy,
      lessThan(tester.getTopLeft(find.text('Members')).dy),
    );
  });

  testWidgets('warn turns the value to the danger color, nothing else', (
    tester,
  ) async {
    await _pump(
      tester,
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AdminStatTile(label: 'Pool', value: 'full', warn: true),
          AdminStatTile(label: 'Idle', value: 'ok'),
        ],
      ),
    );

    expect(_valueColor(tester, 'full'), AppTokens.light.dangerText);
    expect(_valueColor(tester, 'ok'), AppTokens.light.textPrimary);
  });

  testWidgets('the loading skeleton is exactly as wide as the real tile', (
    tester,
  ) async {
    await _pump(tester, const AdminStatTileGhost());

    expect(
      tester.getSize(find.byType(AdminStatTileGhost)).width,
      adminStatTileWidth,
    );
  });
}
