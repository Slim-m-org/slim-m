// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A group DM row's menu: leave, rename and delete it, and the armed sheet each opens.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_data/data.dart';

import 'group_dm_harness.dart';

Channel _row() => const Channel(
  id: 'g1',
  name: 'Person1 and Person2',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmMemberIds: 'self,u1,u2',
);

Future<void> _openRowMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byType(DmRow)),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the row menu offers leave, rename and delete', (tester) async {
    final container = groupDmContainer(GroupDmServer());
    await pumpGroupDm(
      tester,
      container,
      DmRow(channel: _row(), selected: false),
    );
    await _openRowMenu(tester);

    expect(find.text('Leave group'), findsOneWidget);
    expect(find.text('Rename group'), findsOneWidget);
    expect(find.text('Delete group'), findsOneWidget);
    await finishGroupDm(tester, container);
  });

  Future<ProviderContainer> openMenuItem(
    WidgetTester tester,
    String item, {
    GroupDmServer? server,
    Size? size,
  }) async {
    final container = groupDmContainer(server ?? GroupDmServer());
    final store = await container.read(storeProvider.future);
    await store.upsertChannels([
      const api.Channel(
        id: 'g1',
        name: 'Person1 and Person2',
        kind: dmChannelKind,
        createdAt: 0,
        dmMemberIds: ['self', 'u1', 'u2'],
      ),
    ]);
    await pumpGroupDm(
      tester,
      container,
      DmRow(channel: _row(), selected: false),
      size: size ?? const Size(1280, 900),
    );
    await _openRowMenu(tester);
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('Leave group asks first, then leaves and drops the row', (
    tester,
  ) async {
    final server = GroupDmServer();
    final container = await openMenuItem(tester, 'Leave group', server: server);
    expect(server.requests.where((r) => r.endsWith('/leave')), isEmpty);

    await tester.tap(find.textContaining('Leave Person1'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('POST /dms/groups/g1/leave'));
    final store = await container.read(storeProvider.future);
    expect(await store.hasChannel('g1'), isFalse);
    expect(find.text('rail'), findsOneWidget);
    await finishGroupDm(tester, container);
  });

  testWidgets('Delete group says it is for everyone and permanent', (
    tester,
  ) async {
    final server = GroupDmServer();
    final container = await openMenuItem(
      tester,
      'Delete group',
      server: server,
      size: const Size(390, 844),
    );
    expect(find.textContaining('for everyone'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('Person1 and Person2'), findsWidgets);
    expect(server.requests.where((r) => r.startsWith('DELETE')), isEmpty);

    await tester.tap(find.text('Delete Person1 and Person2'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('DELETE /dms/groups/g1'));
    final store = await container.read(storeProvider.future);
    expect(await store.hasChannel('g1'), isFalse);
    await finishGroupDm(tester, container);
  });

  testWidgets('a failed delete stays in the sheet as an error, not a toast', (
    tester,
  ) async {
    final server = GroupDmServer()
      ..failNext = jsonResponse({'error': 'x'}, 500);
    final container = await openMenuItem(
      tester,
      'Delete group',
      server: server,
    );
    await tester.tap(find.text('Delete Person1 and Person2'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final store = await container.read(storeProvider.future);
    expect(await store.hasChannel('g1'), isTrue);
    await finishGroupDm(tester, container);
  });

  testWidgets('Rename group opens the sheet on the name field', (tester) async {
    final container = await openMenuItem(tester, 'Rename group');
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode
          .hasFocus,
      isTrue,
    );
    await finishGroupDm(tester, container);
  });

  testWidgets('the details sheet offers delete beside leave', (tester) async {
    final server = await openMembersSheet(tester);
    expect(find.text('Leave group'), findsOneWidget);
    expect(find.text('Delete group'), findsOneWidget);
    expect(server.writes, 0);
  });
}
