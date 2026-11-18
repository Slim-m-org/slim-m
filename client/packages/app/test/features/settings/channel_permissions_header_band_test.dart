// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The grid's column names sit in a band as tall as its tallest column, every
/// column starting at one line, and once the band is pinned over scrolled
/// rows it closes the card's frame along its top.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/category_permissions_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_body.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_header.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../channels/category_private_fixture.dart';

const _roles = [
  ...privateRoles,
  api.Role(
    id: 'minecraft',
    name: 'minecraft',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
  ),
];

final _band = find.byWidgetPredicate((w) => w is HeaderRow);
final _shields = find.descendant(
  of: _band,
  matching: find.byWidgetPredicate(
    (w) => w is Icon && w.icon == AppIcons.shield,
  ),
);
final _surface = find.byKey(pinnedHeaderSurfaceKey);

Future<void> _openGrid(WidgetTester tester) async {
  final server = OverwriteServer({
    '/categories/sub': [
      // Two summary lines in one column, one in the other.
      {
        'kind': 'role',
        'id': 'everyone',
        'allow': Perm.speak,
        'deny': Perm.viewChannel,
      },
      {'kind': 'role', 'id': 'minecraft', 'allow': Perm.viewChannel, 'deny': 0},
    ],
  });
  await openCategorySheet(
    tester,
    server,
    parentName: null,
    roles: _roles,
    permissions: everyPermission,
  );
  await tester.tap(find.byKey(categoryAdvancedToggleKey));
  await pumpFrames(tester);
}

Border _border(WidgetTester tester) =>
    (tester.widget<DecoratedBox>(_surface).decoration as BoxDecoration).border!
        as Border;

void main() {
  testWidgets('every column starts at the same line', (tester) async {
    await _openGrid(tester);

    expect(_shields, findsNWidgets(2));
    expect(
      tester.getRect(_shields.first).top,
      tester.getRect(_shields.last).top,
    );
  });

  testWidgets('the band leaves no empty strip above its columns', (
    tester,
  ) async {
    await _openGrid(tester);

    final band = tester.getRect(_band);
    final everyone = find.byTooltip(everyoneColumnTooltip);
    final cellTop = tester.getRect(_shields.first).top - 2;
    final cellBottom = tester.getRect(everyone).bottom;
    expect(cellTop - band.top, lessThanOrEqualTo(AppSpacing.s12));
    expect(band.bottom - cellBottom, lessThanOrEqualTo(AppSpacing.s8));
  });

  testWidgets('pinned over the rows, the band closes the frame on top', (
    tester,
  ) async {
    await _openGrid(tester);
    expect(_border(tester).top, BorderSide.none, reason: 'at rest');

    final body = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .last;
    await tester.drag(body, const Offset(0, -700));
    await pumpFrames(tester);

    expect(_border(tester).top, isNot(BorderSide.none));
  });
}
