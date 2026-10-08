// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid's find-and-scan aids: the filter, collapsible groups,
/// the edited-cell marker, the per-column summary and the add control, at
/// desktop and phone width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid_rows.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_header.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

final _channel = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Widget _grid({List<api.ChannelOverwrite> overwrites = const []}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith((ref) async => const []),
      channelOverwritesProvider(
        _channel.id,
      ).overrideWith((ref) async => overwrites),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.sendMessages | Perm.addReactions),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
    ),
  );
}

Finder _cell(int bit) => find.byKey(ValueKey('cell:role:role-everyone:$bit'));

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester, Size size) async {
  _size(tester, size);
  await tester.pumpWidget(_grid());
  await tester.pumpAndSettle();
}

const _desktop = Size(880, 900);
const _phone = Size(390, 844);

void main() {
  testWidgets('the filter keeps only matching permissions and says so when '
      'nothing matches', (tester) async {
    await _open(tester, _desktop);
    expect(_cell(Perm.sendMessages), findsOneWidget);
    final before = tester.getTopLeft(_cell(Perm.addReactions)).dy;

    await tester.enterText(find.byType(EditableText), 'reactions');
    await tester.pumpAndSettle();
    expect(_cell(Perm.sendMessages), findsNothing);
    expect(_cell(Perm.addReactions), findsOneWidget);
    expect(
      tester.getTopLeft(_cell(Perm.addReactions)).dy,
      lessThan(before),
      reason: 'the surviving row moves up into the freed space',
    );

    await tester.enterText(find.byType(EditableText), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('No permissions match that filter.'), findsOneWidget);
  });

  testWidgets('a group header folds its rows and the next group moves up by '
      'exactly those rows', (tester) async {
    await _open(tester, _desktop);
    final groups = Perm.groups;
    final rows = groups.first.permissions.length;
    final nextHeader = find.text(groups[1].title.toUpperCase());
    final open = tester.getTopLeft(nextHeader).dy;

    await tester.tap(find.text(groups.first.title.toUpperCase()));
    await tester.pumpAndSettle();
    expect(_cell(Perm.sendMessages), findsNothing);
    final metrics = GridMetrics.forWidth(_desktop.width, columnCount: 1);
    expect(
      open - tester.getTopLeft(nextHeader).dy,
      closeTo(rows * metrics.rowHeight, 0.5),
    );

    await tester.tap(find.textContaining(groups.first.title.toUpperCase()));
    await tester.pumpAndSettle();
    expect(_cell(Perm.sendMessages), findsOneWidget);
    expect(tester.getTopLeft(nextHeader).dy, closeTo(open, 0.5));
  });

  testWidgets('an edited cell carries a dot on its corner until discarded', (
    tester,
  ) async {
    await _open(tester, _desktop);
    final dot = find.byKey(const ValueKey('cell-changed-dot'));
    expect(dot, findsNothing);

    await tester.tap(_cell(Perm.sendMessages));
    await tester.pumpAndSettle();
    expect(dot, findsOneWidget);
    final chip = tester.getRect(
      find.descendant(
        of: _cell(Perm.sendMessages),
        matching: find.byType(CellChip),
      ),
    );
    final center = tester.getCenter(dot);
    expect(center.dx, closeTo(chip.right, 4));
    expect(center.dy, closeTo(chip.top, 4));

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(dot, findsNothing);
  });

  testWidgets('the column header counts what the overwrite allows and denies', (
    tester,
  ) async {
    await _open(tester, _desktop);
    final summary = find.byKey(const ValueKey('summary:role:role-everyone'));
    expect(
      find.descendant(of: summary, matching: find.text('No overrides')),
      findsOneWidget,
    );

    await tester.tap(_cell(Perm.sendMessages));
    await tester.tap(_cell(Perm.addReactions));
    await tester.tap(_cell(Perm.addReactions));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: summary, matching: find.text('1 allow')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summary, matching: find.text('1 deny')),
      findsOneWidget,
    );
  });

  testWidgets('desktop adds a labelled button above the grid', (tester) async {
    await _open(tester, _desktop);
    final button = find.text('Add role or member');
    expect(button, findsOneWidget);
    expect(
      tester.getTopLeft(button).dy,
      lessThan(tester.getTopLeft(find.byType(HeaderRow)).dy),
    );
  });

  testWidgets('phone adds a 44dp icon above the grid, not a wide button', (
    tester,
  ) async {
    await _open(tester, _phone);
    expect(find.text('Add role or member'), findsNothing);
    final icon = find.byWidgetPredicate(
      (w) => w is AppIconButton && w.semanticLabel == 'Add a role or member',
    );
    expect(icon, findsOneWidget);
    final target = tester.getSize(icon);
    expect(target.shortestSide, greaterThanOrEqualTo(44));
  });
}
