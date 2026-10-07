// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the message row: grouping must be visible in what actually
/// renders (the avatar and the gutter timestamp), not just in the flag
/// passed in, since that flag is exactly what a caller could get backwards.
///
/// Scope is the row's own rendering. Its context menu and its inline edit are
/// separate widgets and have their own files, which is what brought this back
/// under the line budget.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/message_row_identity.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  testWidgets('an ungrouped row shows the avatar and the author name', (
    tester,
  ) async {
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

    expect(find.byType(AppAvatar), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets(
    'a grouped continuation drops the avatar and the name, and shows no '
    'gutter timestamp at rest',
    (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(),
            grouped: true,
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

      expect(find.byType(AppAvatar), findsNothing);
      expect(find.text('Priya'), findsNothing);
      // The owner's ask: not a persistent left-gutter timestamp. Hovering to
      // reveal it is message_row_time_format_test.dart's job.
      expect(find.byType(MessageTimeMark), findsNothing);
    },
  );

  testWidgets(
    'a pending grouped continuation still shows its gutter mark at rest',
    (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(pending: true),
            grouped: true,
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

      // Delivery state, not decoration - never hover-gated.
      expect(find.byType(MessageTimeMark), findsOneWidget);
      expect(find.byIcon(AppIcons.clock), findsOneWidget);
    },
  );

  testWidgets(
    'a failed grouped continuation still shows its gutter mark at rest',
    (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(failed: true),
            grouped: true,
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

      expect(find.byType(MessageTimeMark), findsOneWidget);
      expect(find.byIcon(AppIcons.failed), findsOneWidget);
    },
  );

  testWidgets(
    'hovering a grouped continuation reveals the gutter timestamp, and '
    'leaving hides it again',
    (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(),
            grouped: true,
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

      expect(find.byType(MessageTimeMark), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
      await tester.pumpAndSettle();

      expect(find.byType(MessageTimeMark), findsOneWidget);

      await mouse.moveTo(const Offset(2000, 2000));
      await tester.pumpAndSettle();

      expect(find.byType(MessageTimeMark), findsNothing);
    },
  );

  testWidgets(
    "the group's first message still shows the header time after the name, "
    'unhovered',
    (tester) async {
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

      expect(find.byType(MessageTimeMark), findsOneWidget);
    },
  );

  testWidgets('the "New" divider only appears when asked for', (tester) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: true,
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
    expect(find.text('NEW'), findsOneWidget);

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
    expect(find.text('NEW'), findsNothing);
  });

  testWidgets('a failed send shows the retry and discard actions', (
    tester,
  ) async {
    var retried = false;
    var discarded = false;
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(failed: true),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          callbacks: MessageRowCallbacks(
            onRetry: () => retried = true,
            onDiscard: () => discarded = true,
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Discard'));
    expect(retried, isTrue);
    expect(discarded, isTrue);
  });

  testWidgets('a failed send names why, not just that it failed', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(
            failed: true,
            failureReason:
                'Could not send the message. '
                'message is 37 characters over the 4000-character limit.',
          ),
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

    expect(
      find.textContaining('37 characters over the 4000-character limit'),
      findsOneWidget,
    );
  });

  testWidgets('a failed send with no recorded reason shows none, rather than a '
      'placeholder', (tester) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(failed: true),
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

    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('character limit'), findsNothing);
  });
}
