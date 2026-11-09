// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Group DMs (decision 0095) on the client: the default name, the rail row,
/// the new-group sheet's rules, and the members sheet's add, rename and leave.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/channels/providers/group_dm.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_app/src/features/channels/widgets/group_avatar_stack.dart';
import 'package:slimm_app/src/features/channels/widgets/group_dm_members_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'group_dm_harness.dart';

void main() {
  group('defaultGroupName', () {
    test('lists up to three names, then counts the rest', () {
      expect(defaultGroupName(['A']), 'A');
      expect(defaultGroupName(['A', 'B']), 'A and B');
      expect(defaultGroupName(['A', 'B', 'C']), 'A, B and C');
      expect(defaultGroupName(['A', 'B', 'C', 'D']), 'A, B and 2 others');
      expect(
        defaultGroupName(['A', 'B', 'C', 'D', 'E', 'F', 'G']),
        'A, B and 5 others',
      );
      expect(defaultGroupName(const []), 'Group');
    });
  });

  group('channelFromDm for a group', () {
    test('names it from the others and keeps the whole roster', () {
      final channel = channelFromDm(
        api.DmConversation.fromJson(groupJson()),
        selfId: 'self',
      );
      expect(channel.name, 'Person1 and Person2');
      expect(channel.kind, dmChannelKind);
      expect(channel.dmMemberIds, ['self', 'u1', 'u2']);
      expect(channel.isGroupDm, isTrue);
      expect(
        channel.dmParticipantId,
        isNull,
        reason: 'nobody to block or report',
      );
      expect(channel.isPersonalSpace, isFalse);
    });

    test('a custom name wins over the default', () {
      final channel = channelFromDm(
        api.DmConversation.fromJson(groupJson(name: 'trip')),
        selfId: 'self',
      );
      expect(channel.name, 'trip');
    });
  });

  group('the rail row', () {
    Channel row() => const Channel(
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

    testWidgets('draws two overlapping avatars inside one row avatar slot', (
      tester,
    ) async {
      final container = groupDmContainer(GroupDmServer());
      await pumpGroupDm(
        tester,
        container,
        DmRow(channel: row(), selected: false),
      );

      final stack = find.byType(GroupAvatarStack);
      expect(stack, findsOneWidget);
      final box = tester.getRect(stack);
      expect(box.size, const Size(28, 28));
      final faces = find.descendant(
        of: stack,
        matching: find.byType(AppAvatar),
      );
      expect(faces, findsNWidgets(2));
      final first = tester.getRect(faces.at(0));
      final second = tester.getRect(faces.at(1));
      expect(
        box.contains(first.topLeft) && box.contains(first.bottomRight),
        isTrue,
      );
      expect(
        box.contains(second.topLeft) && box.contains(second.bottomRight),
        isTrue,
      );
      expect(
        first.overlaps(second),
        isTrue,
        reason: 'stacked, not side by side',
      );
      expect(second.center.dx, greaterThan(first.center.dx));
      expect(second.center.dy, greaterThan(first.center.dy));
      await finishGroupDm(tester, container);
    });

    testWidgets('offers Group members, and no close, report or block', (
      tester,
    ) async {
      final container = groupDmContainer(GroupDmServer());
      await pumpGroupDm(
        tester,
        container,
        DmRow(channel: row(), selected: false),
      );

      await tester.tapAt(
        tester.getCenter(find.byType(DmRow)),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.text('Group members'), findsOneWidget);
      expect(find.text('Close DM'), findsNothing);
      expect(find.text('Report user'), findsNothing);
      expect(find.text('Block'), findsNothing);
      await finishGroupDm(tester, container);
    });
  });

  group('the new group sheet', () {
    const open = openNewGroupSheet;

    testWidgets('asks for two people, then offers to start', (tester) async {
      await open(tester);
      expect(find.text('Pick 2 more'), findsOneWidget);

      await tester.tap(personTile('u1'));
      await tester.pump();
      expect(find.text('Pick 1 more'), findsOneWidget);

      await tester.tap(personTile('u2'));
      await tester.pump();
      expect(find.text('Start group with 3 people'), findsOneWidget);
    });

    testWidgets('holds at ten people, the caller included', (tester) async {
      await open(tester);
      for (var i = 1; i <= 9; i++) {
        await tester.ensureVisible(personTile('u$i'));
        await tester.tap(personTile('u$i'));
        await tester.pump();
      }
      expect(find.text('Start group with 10 people'), findsOneWidget);

      await tester.ensureVisible(personTile('u10'));
      await tester.tap(personTile('u10'), warnIfMissed: false);
      await tester.pump();
      expect(
        find.text('Start group with 10 people'),
        findsOneWidget,
        reason: 'a tenth other person is not added',
      );
    });

    testWidgets('starts the group with a UUIDv7 id and opens it', (
      tester,
    ) async {
      final server = await open(tester);
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await tester.tap(find.text('Start group with 3 people'));
      await tester.pumpAndSettle();

      final post = server.requests.firstWhere(
        (r) => r.startsWith('POST /dms/groups '),
      );
      final body =
          jsonDecode(post.substring('POST /dms/groups '.length))
              as Map<String, dynamic>;
      expect(body['user_ids'], unorderedEquals(['u1', 'u2']));
      expect(body['id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(body.containsKey('name'), isFalse);
      expect(find.text('open:g1'), findsOneWidget);
    });

    testWidgets('fits a phone width without overflow', (tester) async {
      await open(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('New group message'), findsOneWidget);
    });
  });

  group('the members sheet', () {
    const open = openMembersSheet;

    testWidgets('lists everyone, marks the caller, and says how many', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('3 of 10 people'), findsOneWidget);
      expect(find.text('Me (you)'), findsOneWidget);
      expect(find.text('Person1'), findsWidgets);
      expect(find.text('Person2'), findsWidgets);
    });

    testWidgets(
      'adding someone sends the id, and the roster is offered without members',
      (tester) async {
        final server = await open(tester);
        expect(personTile('u1'), findsNothing, reason: 'already in the group');
        await tester.ensureVisible(personTile('u3'));
        await tester.tap(personTile('u3'));
        await tester.pumpAndSettle();

        expect(
          server.requests,
          contains('POST /dms/groups/g1/members {"user_id":"u3"}'),
        );
      },
    );

    testWidgets('renaming sends the name, and Save waits for a change', (
      tester,
    ) async {
      final server = await open(tester);
      final save = find.widgetWithText(AppButton, 'Save');
      expect(tester.widget<AppButton>(save).disabled, isTrue);

      await tester.enterText(find.byType(EditableText).first, 'trip');
      await tester.pump();
      expect(tester.widget<AppButton>(save).disabled, isFalse);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(server.requests, contains('PATCH /dms/groups/g1 {"name":"trip"}'));
    });

    testWidgets('leaving asks first, then leaves and goes back to the list', (
      tester,
    ) async {
      final server = await open(tester);
      await tester.ensureVisible(find.text('Leave group'));
      await tester.tap(find.text('Leave group'));
      await tester.pumpAndSettle();
      expect(
        server.requests.where((r) => r.endsWith('/leave')),
        isEmpty,
        reason: 'one tap only asks',
      );

      await tester.tap(find.textContaining('Leave Person1'));
      await tester.pumpAndSettle();

      expect(server.requests, contains('POST /dms/groups/g1/leave'));
      expect(find.text('rail'), findsOneWidget);
    });

    testWidgets('cancelling the leave keeps the sheet and sends nothing', (
      tester,
    ) async {
      final server = await open(tester);
      await tester.ensureVisible(find.text('Leave group'));
      await tester.tap(find.text('Leave group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(server.requests.where((r) => r.endsWith('/leave')), isEmpty);
      expect(find.text('Leave group'), findsOneWidget);
    });

    testWidgets('a full group offers no add list', (tester) async {
      final server = GroupDmServer()
        ..listing = [
          groupJson(members: ['self', for (var i = 1; i <= 9; i++) 'u$i']),
        ];
      final container = groupDmContainer(server);
      addTearDown(container.dispose);
      await pumpGroupDm(
        tester,
        container,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showGroupDmMembersSheet(context, 'g1'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('This group is full.'), findsOneWidget);
      expect(find.text('Add someone'), findsNothing);
    });
  });
}
