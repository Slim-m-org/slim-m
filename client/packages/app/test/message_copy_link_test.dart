// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Copying a link to a message: the gate, the menu item, and the write.
///
/// The parsing half of message links was tested properly and this half was
/// not. Every context-menu suite hardcodes `canCopyLink: false`, so the item
/// at `message_context_menu.dart:217` had never once been rendered or tapped
/// under a test, and `copyMessageLink` never reached a clipboard.
///
/// Each case below names a mutation it exists to fail, because "has a test"
/// and "would notice" are different claims.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/screens/channel_message_actions.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  group('canCopyMessageLink', () {
    // Fails: `=> true`, and `=> false`.
    test('allows a message the server has acknowledged', () {
      expect(canCopyMessageLink(message()), isTrue);
    });

    test('refuses one still in flight, whose id names no row yet', () {
      expect(canCopyMessageLink(message(pending: true)), isFalse);
      expect(canCopyMessageLink(message(failed: true)), isFalse);
    });
  });

  group('the menu item', () {
    // Fails: inverting `if (actions.canCopyLink)`, or dropping the item.
    testWidgets('appears only when the caller allows it, and calls back', (
      tester,
    ) async {
      var copied = 0;
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(),
            grouped: false,
            showNewDivider: false,
            knownUsernames: const {},
            actions: MessageActions(
              canReply: false,
              onReply: noop,
              canEdit: false,
              onEdit: noop,
              canDelete: false,
              onDelete: noop,
              canManagePins: false,
              pinned: false,
              onTogglePin: noop,
              canReport: false,
              onReport: noop,
              canBlockAuthor: false,
              onBlockAuthor: noop,
              canOpenThread: false,
              onOpenThread: noop,
              canCopyLink: true,
              onCopyLink: () => copied += 1,
              canForward: false,
              onForward: noop,
              canSave: false,
              onSave: noop,
            ),
            editing: false,
            callbacks: MessageRowCallbacks(
              onRetry: () {},
              onDiscard: () {},
              onPickReaction: (_) {},
              onReactionTap: (_) {},
              onVote: (_) {},
              onSubmitEdit: (_) {},
              onCancelEdit: () {},
            ),
          ),
        ),
      );

      await tester.longPressAt(
        tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
            const Offset(30, 30),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy link'), findsOneWidget);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, 1, reason: 'tapping it has to reach onCopyLink');
    });

    // Fails: making the item unconditional.
    testWidgets('stays away when the caller refuses it', (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(),
            grouped: false,
            showNewDivider: false,
            knownUsernames: const {},
            actions: noActions,
            editing: false,
            callbacks: MessageRowCallbacks(
              onRetry: () {},
              onDiscard: () {},
              onPickReaction: (_) {},
              onReactionTap: (_) {},
              onVote: (_) {},
              onSubmitEdit: (_) {},
              onCancelEdit: () {},
            ),
          ),
        ),
      );

      await tester.longPressAt(
        tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
            const Offset(30, 30),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy text'), findsOneWidget, reason: 'menu did open');
      expect(find.text('Copy link'), findsNothing);
    });
  });

  group('the clipboard write', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    /// Drives the real `copyMessageLink` rather than a clipboard call beside
    /// it. The first version of this test wrote the link itself and asserted
    /// on that, which would have stayed green against the very mutation it
    /// was written for - a `copyMessageLink` that never touches the clipboard.
    // Fails: a no-op copyMessageLink; one that drops the toast.
    testWidgets('puts the message link on the clipboard, and says so', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          serverUrlProvider.overrideWithValue(
            Uri.parse('https://slim.example'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => copyMessageLink(
                    ref,
                    context,
                    channelId: 'c1',
                    message: message(),
                  ),
                  child: const Text('copy'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('copy'));
      await tester.pumpAndSettle();

      final write = calls.singleWhere((c) => c.method == 'Clipboard.setData');
      final text = (write.arguments as Map)['text'] as String;
      expect(
        text,
        buildMessageLink(
          server: Uri.parse('https://slim.example'),
          channelId: 'c1',
          messageId: 'm1',
        ),
        reason: 'the clipboard gets the link this message actually resolves to',
      );
      // Read off the provider: the toast host is not mounted here.
      expect(
        container.read(toastsProvider).map((t) => t.message),
        contains('Link copied.'),
        reason: 'a clipboard write is invisible; the toast is the confirmation',
      );

      // Drain the toast's dismissal timer, or the binding fails on it.
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
