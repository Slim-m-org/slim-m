// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pointing at a permissions grid cell tints its whole row, the permission's
/// name included, strengthens the cell's own edge, and names the permission,
/// the column and the state in a tooltip. A disabled cell keeps its
/// disabled look under the pointer.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/category_permissions_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_cell.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../channels/category_private_fixture.dart';

final _cell = find.byKey(
  const ValueKey('cell:role:everyone:${Perm.sendMessages}'),
);

Future<TestGesture> _hoverCell(WidgetTester tester) async {
  await openCategorySheet(
    tester,
    OverwriteServer({'/categories/sub': []}),
    parentName: null,
    permissions: everyPermission,
  );
  await tester.tap(find.byKey(categoryAdvancedToggleKey));
  await pumpFrames(tester);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(_cell));
  await tester.pump(cellTooltipWait * 2);
  await pumpFrames(tester);
  return mouse;
}

/// The tint behind [of], read from the nearest animated row background.
Color? _tint(WidgetTester tester, Finder of) {
  final box = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: of,
          matching: find.byWidgetPredicate((w) => w is AnimatedContainer),
        )
        .first,
  );
  return (box.decoration as BoxDecoration?)?.color;
}

AppTokens get _light => AppTokens.light;

/// Fill, border and glyph colours and the scale of a lone chip.
Future<(Color?, Color, Color?, double)> _chipLook(
  WidgetTester tester,
  CellChip chip,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Center(child: chip),
    ),
  );
  await pumpFrames(tester);
  final box = tester.widget<AnimatedContainer>(
    find.byWidgetPredicate((w) => w is AnimatedContainer),
  );
  final decoration = box.decoration! as BoxDecoration;
  final icon = tester.widget<Icon>(find.byWidgetPredicate((w) => w is Icon));
  return (
    decoration.color,
    (decoration.border! as Border).top.color,
    icon.color,
    tester
        .widget<AnimatedScale>(
          find.byWidgetPredicate((w) => w is AnimatedScale),
        )
        .scale,
  );
}

void main() {
  testWidgets('the row tints from its name to its last cell', (tester) async {
    final mouse = await _hoverCell(tester);

    expect(_tint(tester, find.text('Send messages')), _light.surfaceBase);
    expect(_tint(tester, _cell), _light.surfaceBase);
    expect(
      _tint(tester, find.text('Manage messages')),
      isNot(_light.surfaceBase),
    );

    await mouse.moveTo(Offset.zero);
    await pumpFrames(tester);
    expect(
      _tint(tester, find.text('Send messages')),
      isNot(_light.surfaceBase),
    );
  });

  testWidgets('the hovered cell strengthens its edge', (tester) async {
    await _hoverCell(tester);

    final chip = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: _cell,
            matching: find.byWidgetPredicate((w) => w is AnimatedContainer),
          )
          .first,
    );
    final border = (chip.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color, _light.borderStrong);
  });

  testWidgets('a tooltip names the permission, the column and the state', (
    tester,
  ) async {
    await _hoverCell(tester);

    expect(
      find.text('Send messages for everyone: Inherit from role'),
      findsOneWidget,
    );
  });

  testWidgets('a disabled cell looks the same hovered or pressed', (
    tester,
  ) async {
    for (final state in CellState.values) {
      final rest = await _chipLook(
        tester,
        CellChip(state: state, disabled: true),
      );
      final hovered = await _chipLook(
        tester,
        CellChip(state: state, disabled: true, hovered: true),
      );
      final pressed = await _chipLook(
        tester,
        CellChip(state: state, disabled: true, pressed: true),
      );
      expect(hovered, rest, reason: '$state hovered');
      expect(pressed, rest, reason: '$state pressed');
    }
  });
}
