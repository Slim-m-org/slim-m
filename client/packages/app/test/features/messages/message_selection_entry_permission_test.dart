// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permission gate on entering bulk-select, at its one real call site.
///
/// `messageActionsFor` wires `onStartSelecting` for the whole app; a plain
/// member holding no MANAGE_MESSAGES must never get it, even for their own
/// message, where `canDeleteMessage` is already true through authorship
/// alone. Everything downstream - the context menu, the selection bar -
/// trusts this wiring completely, so a hole here is a hole everywhere: once
/// selection mode starts, any visible message can be added to it, not just
/// the one the menu was opened on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/messages/providers/message_selection.dart';
import 'package:slimm_app/src/features/channels/screens/channel_message_actions.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _channel = 'c1';

Message _message({required String authorId}) => Message(
  id: 'm1',
  channelId: _channel,
  authorId: authorId,
  authorDisplayName: 'name',
  seq: 1,
  content: 'hi',
  createdAt: 0,
  pending: false,
  failed: false,
);

Future<MessageActions> _actionsFor(
  WidgetTester tester, {
  required int myPermissions,
  required String authorId,
}) async {
  late MessageActions actions;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            actions = messageActionsFor(
              ref,
              context,
              _message(authorId: authorId),
              channelId: _channel,
              channelIsThread: false,
              hasExistingThread: false,
              myId: 'self',
              myPermissions: myPermissions,
              pinnedIds: const {},
              onReply: (_) {},
              onEdit: (_) {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return actions;
}

void main() {
  group('messageActionsFor wiring', () {
    testWidgets(
      'a MANAGE_MESSAGES holder gets the entry point on any message',
      (tester) async {
        final actions = await _actionsFor(
          tester,
          myPermissions: Perm.manageMessages,
          authorId: 'other',
        );
        expect(actions.onStartSelecting, isNotNull);
      },
    );

    testWidgets(
      'a plain member never gets the entry point, even on their own message',
      (tester) async {
        final actions = await _actionsFor(
          tester,
          myPermissions: 0,
          authorId: 'self',
        );
        expect(
          actions.onStartSelecting,
          isNull,
          reason:
              'canDeleteMessage is already true here through authorship '
              'alone; the entry point needs MANAGE_MESSAGES specifically, '
              'or a plain member could open bulk-select from their own '
              "message and then pick somebody else's",
        );
      },
    );

    testWidgets('a plain member gets no entry point on another author either', (
      tester,
    ) async {
      final actions = await _actionsFor(
        tester,
        myPermissions: 0,
        authorId: 'other',
      );
      expect(actions.onStartSelecting, isNull);
    });
  });

  group('the entry point, tapped through the real menu', () {
    /// [messageSelectionProvider] is `autoDispose`; the `Scaffold`'s `body`
    /// watches it the way `ChannelComposerArea` always does in the real app,
    /// so with nothing holding it alive, `start` inside the tapped menu item
    /// would set state on an instance immediately torn down again.
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required int myPermissions,
      required String authorId,
    }) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  ref.watch(messageSelectionProvider(_channel));
                  return MessageContextMenuRegion(
                    content: 'hi',
                    actions: messageActionsFor(
                      ref,
                      context,
                      _message(authorId: authorId),
                      channelId: _channel,
                      channelIsThread: false,
                      hasExistingThread: false,
                      myId: 'self',
                      myPermissions: myPermissions,
                      pinnedIds: const {},
                      onReply: (_) {},
                      onEdit: (_) {},
                    ),
                    onAddReaction: () {},
                    onPickReaction: (_) {},
                    child: const SizedBox(height: 40, width: 200),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('a holder can open the menu, select it, and enter the mode', (
      tester,
    ) async {
      final container = await pump(
        tester,
        myPermissions: Perm.manageMessages,
        authorId: 'other',
      );

      await tester.longPress(find.byType(MessageContextMenuRegion));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Select messages'), findsOneWidget);

      await tester.tap(find.text('Select messages'));
      await tester.pumpAndSettle();

      final selection = container.read(messageSelectionProvider(_channel));
      expect(selection.active, isTrue);
      expect(selection.contains('m1'), isTrue);
    });

    testWidgets('a non-holder never sees the item and cannot reach the mode', (
      tester,
    ) async {
      final container = await pump(tester, myPermissions: 0, authorId: 'self');

      await tester.longPress(find.byType(MessageContextMenuRegion));
      await tester.pumpAndSettle();

      expect(find.text('Select messages'), findsNothing);
      expect(
        find.text('Delete'),
        findsOneWidget,
        reason: 'their own single delete is still offered',
      );
      expect(
        container.read(messageSelectionProvider(_channel)).active,
        isFalse,
      );
    });
  });
}
