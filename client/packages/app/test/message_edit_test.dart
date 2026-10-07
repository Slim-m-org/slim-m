// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the message row's inline edit: the body swaps for a pre-filled
/// [MessageEditField], and saving and cancelling each report exactly once.
///
/// Split out of `message_row_test.dart` on the widget seam, the same way the
/// context menu suite was.
///
/// The defect these pin: the field's Save and Cancel controls, plus a
/// hardware-only hint, ran in one `Row` with no way to shrink, so on a real
/// phone width they overflowed and Save sat off past the right edge of the
/// screen - present in the tree, reachable by nothing a thumb could do. The
/// hint is now hidden on a soft keyboard and the row fits.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_edit_field.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _phoneSize = Size(390, 844);

void main() {
  testWidgets('editing swaps the body for a pre-filled field', (tester) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: true,
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

    expect(find.byType(MessageEditField), findsOneWidget);
    expect(find.widgetWithText(TextField, 'hello there'), findsOneWidget);
  });

  testWidgets('saving reports the edited text', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: true,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (text) => submitted = text,
            onCancelEdit: () {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'edited content');
    await tester.tap(find.text('Save'));

    expect(submitted, 'edited content');
  });

  testWidgets('cancel leaves the row rendered as unedited', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(),
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: true,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () => cancelled = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Cancel'));
    expect(cancelled, isTrue);
  });

  testWidgets('touch layout: Save is reachable and commits the edited text', (
    tester,
  ) async {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? submitted;

    await tester.pumpWidget(
      harness(_editingRow(onSubmitEdit: (text) => submitted = text)),
    );

    // The bug this pins: Save used to overflow off the phone's right edge.
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'fixed on the phone');
    await tester.tap(find.text('Save'));

    expect(submitted, 'fixed on the phone');
  });

  testWidgets('touch layout: Cancel is reachable and cancels', (tester) async {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var cancelled = false;

    await tester.pumpWidget(
      harness(_editingRow(onCancelEdit: () => cancelled = true)),
    );

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Cancel'));
    expect(cancelled, isTrue);
  });

  testWidgets(
    'touch layout: no hardware-only hint, and the row does not overflow',
    (tester) async {
      tester.view.physicalSize = _phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(_editingRow()));

      expect(tester.takeException(), isNull);
      expect(find.byType(AppKbd), findsNothing);
    },
  );

  testWidgets(
    'desktop keyboard path is unchanged: Enter saves, Escape cancels',
    (tester) async {
      String? submitted;
      var cancelled = false;

      await tester.pumpWidget(
        harness(
          _editingRow(
            onSubmitEdit: (text) => submitted = text,
            onCancelEdit: () => cancelled = true,
          ),
          platform: TargetPlatform.linux,
        ),
      );

      // The keycaps naming the shortcuts are desktop-only chrome; still there.
      expect(find.byType(AppKbd), findsNWidgets(4));

      await tester.enterText(find.byType(TextField), 'edited on desktop');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, 'edited on desktop');
      expect(cancelled, isFalse);
    },
  );

  testWidgets('desktop keyboard path is unchanged: Escape cancels', (
    tester,
  ) async {
    var cancelled = false;

    await tester.pumpWidget(
      harness(
        _editingRow(onCancelEdit: () => cancelled = true),
        platform: TargetPlatform.linux,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(cancelled, isTrue);
  });
}

/// A [MessageRow] mid-edit, with every callback the row requires defaulted
/// to a no-op: the tests above each care about at most one of them.
Widget _editingRow({
  ValueChanged<String>? onSubmitEdit,
  VoidCallback? onCancelEdit,
}) => MessageRow(
  message: message(),
  grouped: false,
  showNewDivider: false,
  knownUsernames: const {},
  actions: noActions,
  editing: true,
  callbacks: MessageRowCallbacks(
    onRetry: () {},
    onDiscard: () {},
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: onSubmitEdit ?? (_) {},
    onCancelEdit: onCancelEdit ?? () {},
  ),
);
