// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The report card's quick actions: jump to the message, delete it, time
/// out its author, or remove them from the Space. Each is absent without
/// its permission, present and wired to the right endpoint with it, and a
/// destructive one asks first. Split out of `report_card_test.dart` for the
/// line budget.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_sections.dart'
    show TimeoutDurationChips;
import 'package:slimm_data/data.dart' hide Channel, Message;
import 'package:slimm_design_system/design_system.dart';

import 'report_card_harness.dart';

void main() {
  group('jump to message', () {
    testWidgets('is absent for a user report - there is no message', (
      tester,
    ) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r-user', subjectKind: 'user', subjectId: 'u1'),
        ],
      );

      expect(find.widgetWithText(AppButton, 'Jump to message'), findsNothing);
    });

    testWidgets('is disabled while the channel is not known to be viewable', (
      tester,
    ) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'r-unreachable',
            subjectKind: 'message',
            subjectId: 'm1',
            channelId: 'channel-unknown',
          ),
        ],
        db: db,
      );

      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Jump to message'),
      );
      expect(button.disabled, isTrue);
    });

    testWidgets(
      'jumps to the message once the channel is known to be viewable',
      (tester) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final store = MessageStore(db);
        await store.replaceChannels([
          const Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
        ]);
        await store.applyMessage(
          const Message(
            id: 'm1',
            channelId: 'c1',
            authorId: 'author-1',
            authorDisplayName: 'Author',
            seq: 1,
            content: 'the reported text',
            createdAt: 0,
            editedAt: null,
          ),
        );

        final harness = await pumpReports(
          tester,
          reports: [
            reportJson(
              id: 'r-reachable',
              subjectKind: 'message',
              subjectId: 'm1',
              channelId: 'c1',
            ),
          ],
          db: db,
          router: reportsRouter(),
        );

        final button = tester.widget<AppButton>(
          find.widgetWithText(AppButton, 'Jump to message'),
        );
        expect(button.disabled, isFalse);

        await tester.tap(find.widgetWithText(AppButton, 'Jump to message'));
        await tester.pumpAndSettle();

        expect(find.text('channel c1'), findsOneWidget);
        expect(
          harness.container.read(messageJumpProvider),
          isA<MessageJumpArrived>(),
        );
      },
    );
  });

  group('delete message', () {
    testWidgets('is absent without MANAGE_MESSAGES', (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'r1',
            subjectKind: 'message',
            subjectId: 'm1',
            channelId: 'c1',
          ),
        ],
      );

      expect(find.widgetWithText(AppButton, 'Delete message'), findsNothing);
    });

    testWidgets(
      'is absent when this report\'s own channel lacks MANAGE_MESSAGES, '
      'even though the base (deployment-wide) set has it',
      (tester) async {
        await pumpReports(
          tester,
          reports: [
            reportJson(
              id: 'r1',
              subjectKind: 'message',
              subjectId: 'm1',
              channelId: 'c1',
              channelPermissions: 0,
            ),
          ],
          permissions: Perm.manageMessages,
        );

        expect(find.widgetWithText(AppButton, 'Delete message'), findsNothing);
      },
    );

    testWidgets(
      'is present when this report\'s own channel carries MANAGE_MESSAGES, '
      'even though the base (deployment-wide) set does not',
      (tester) async {
        await pumpReports(
          tester,
          reports: [
            reportJson(
              id: 'r1',
              subjectKind: 'message',
              subjectId: 'm1',
              channelId: 'c1',
              channelPermissions: Perm.manageMessages,
            ),
          ],
        );

        expect(
          find.widgetWithText(AppButton, 'Delete message'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'is absent on a DM report even for an administrator, since the DM '
      "evaluator never grants MANAGE_MESSAGES to anyone",
      (tester) async {
        await pumpReports(
          tester,
          reports: [
            reportJson(
              id: 'r1',
              subjectKind: 'message',
              subjectId: 'm1',
              channelId: 'dm-1',
              // DM_BASE minus manageMessages - no one holds it in a DM.
              channelPermissions: Perm.viewChannel | Perm.sendMessages,
            ),
          ],
          // Every base bit, the real shape an administrator's base set holds.
          permissions: -1,
        );

        expect(find.widgetWithText(AppButton, 'Delete message'), findsNothing);
      },
    );

    testWidgets('confirms, then deletes the message and closes the report', (
      tester,
    ) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final harness = await pumpReports(
        tester,
        reports: [
          reportJson(
            id: 'r1',
            subjectKind: 'message',
            subjectId: 'm1',
            channelId: 'c1',
            channelPermissions: Perm.manageMessages,
          ),
        ],
        db: db,
        permissions: Perm.manageMessages,
      );

      await tester.tap(find.widgetWithText(AppButton, 'Delete message'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        harness.calls.where((c) => c.method == 'DELETE'),
        isEmpty,
        reason: 'nothing should happen before the dialog is confirmed',
      );

      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(AppButton, 'Delete'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        harness.calls,
        contains(const Call('DELETE', '/channels/c1/messages/m1')),
      );
      expect(
        harness.calls,
        contains(const Call('PATCH', '/reports/r1')),
        reason: 'taking the action should also close the report',
      );
    });
  });

  group('time out', () {
    testWidgets('is absent without KICK_MEMBERS', (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r1', subjectKind: 'user', subjectId: 'author-1'),
        ],
      );

      expect(find.byType(TimeoutDurationChips), findsNothing);
    });

    testWidgets('needs no confirmation and closes the report', (tester) async {
      final harness = await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r1', subjectKind: 'user', subjectId: 'author-1'),
        ],
        permissions: Perm.kickMembers,
      );

      await tester.tap(find.widgetWithText(AppButton, '1h'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(
        harness.calls,
        contains(const Call('PUT', '/members/author-1/timeout')),
      );
      expect(harness.calls, contains(const Call('PATCH', '/reports/r1')));
    });

    testWidgets(
      'is absent on your own report of yourself, with a caption saying why',
      (tester) async {
        await pumpReports(
          tester,
          reports: [
            reportJson(id: 'r1', subjectKind: 'user', subjectId: 'mod-1'),
          ],
          permissions: Perm.kickMembers,
        );

        expect(find.byType(TimeoutDurationChips), findsNothing);
        expect(find.textContaining("This report names you"), findsOneWidget);
      },
    );

    testWidgets(
      'the self-target caption stays quiet for a moderator with neither bit',
      (tester) async {
        await pumpReports(
          tester,
          reports: [
            reportJson(id: 'r1', subjectKind: 'user', subjectId: 'mod-1'),
          ],
        );

        expect(find.textContaining('This report names you'), findsNothing);
      },
    );
  });

  group('remove from Space', () {
    testWidgets('is absent without BAN_MEMBERS', (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r1', subjectKind: 'user', subjectId: 'author-1'),
        ],
      );

      expect(
        find.widgetWithText(AppButton, 'Remove from Space...'),
        findsNothing,
      );
    });

    testWidgets('confirms, then removes the member and closes the report', (
      tester,
    ) async {
      final harness = await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r1', subjectKind: 'user', subjectId: 'author-1'),
        ],
        profiles: {'author-1': 'Author Ash'},
        permissions: Perm.banMembers,
      );

      await tester.tap(find.widgetWithText(AppButton, 'Remove from Space...'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        harness.calls.where((c) => c.method == 'PUT'),
        isEmpty,
        reason: 'nothing should happen before the dialog is confirmed',
      );

      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(AppButton, 'Remove'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        harness.calls,
        contains(const Call('PUT', '/members/author-1/removal')),
      );
      expect(harness.calls, contains(const Call('PATCH', '/reports/r1')));
    });

    testWidgets('is absent on your own report of yourself', (tester) async {
      await pumpReports(
        tester,
        reports: [
          reportJson(id: 'r1', subjectKind: 'user', subjectId: 'mod-1'),
        ],
        permissions: Perm.banMembers,
      );

      expect(
        find.widgetWithText(AppButton, 'Remove from Space...'),
        findsNothing,
      );
    });
  });
}
