// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In the category permissions modal, an unsaved grid edit shows Discard and
/// Save in a footer docked to the modal's bottom edge, outside the scrolling
/// body, so it stays put however far the grid scrolls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/category_permissions_sheet.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'category_private_fixture.dart';

final _save = find.text('Save changes');
final _dialog = find.byWidgetPredicate((w) => w is Dialog);
final _body = find
    .descendant(
      of: _dialog,
      matching: find.byWidgetPredicate((w) => w is Scrollable),
    )
    .first;

Future<OverwriteServer> _editOneCell(WidgetTester tester) async {
  final server = OverwriteServer({'/categories/sub': []});
  await openCategorySheet(
    tester,
    server,
    parentName: null,
    size: const Size(1000, 1000),
    permissions: everyPermission,
  );
  await tester.tap(find.byKey(categoryAdvancedToggleKey));
  await pumpFrames(tester);
  await tester.tap(
    find.byKey(const ValueKey('cell:role:everyone:${Perm.sendMessages}')),
  );
  await pumpFrames(tester);
  return server;
}

void main() {
  testWidgets('Save docks to the bottom of the modal, outside its scroll', (
    tester,
  ) async {
    await _editOneCell(tester);

    expect(_save, findsOneWidget);
    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(
      find.ancestor(
        of: _save,
        matching: find.byWidgetPredicate((w) => w is Scrollable),
      ),
      findsNothing,
    );
    final dialog = tester.getRect(
      find
          .descendant(
            of: _dialog,
            matching: find.byWidgetPredicate((w) => w is Material),
          )
          .first,
    );
    final docked = tester.getRect(_save).bottom;
    expect(dialog.bottom - docked, lessThanOrEqualTo(AppSpacing.s24));

    await tester.drag(_body, const Offset(0, -600));
    await pumpFrames(tester);
    expect(tester.getRect(_save).bottom, docked, reason: 'after scrolling');
  });

  testWidgets('Save sends the edit and the footer goes away', (tester) async {
    final server = await _editOneCell(tester);

    await tapAndWait(tester, _save, server);
    await pumpFrames(tester);

    expect(server.writes['/categories/sub'], [
      {'kind': 'role', 'id': 'everyone', 'allow': Perm.sendMessages, 'deny': 0},
    ]);
    expect(_save, findsNothing);
  });

  testWidgets('Discard drops the edit and the footer', (tester) async {
    await _editOneCell(tester);

    await tester.tap(find.text('Discard'));
    await pumpFrames(tester);

    expect(_save, findsNothing);
  });
}
