// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Message-row content tests split out of message_row_test.dart to keep both
/// under the file budget: reactions, attachments, and the emoji panel.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  group('reactions', () {
    testWidgets('a chip shows the real count and reflects whether you reacted', (
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
            extras: MessageExtras(
              reactions: const [
                /// Escaped rather than literal: the hygiene gate forbids emoji
                /// codepoints in client source, and these are user content standing in
                /// for a reaction, not interface chrome.
                api.ReactionSummary(
                  emoji: '\u{1F44D}',
                  count: 3,
                  reacted: true,
                ),
                api.ReactionSummary(
                  emoji: '\u{1F389}',
                  count: 1,
                  reacted: false,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('\u{1F44D}'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('\u{1F389}'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('tapping an existing chip reports which reaction was tapped', (
      tester,
    ) async {
      api.ReactionSummary? tapped;
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
              onReactionTap: (r) => tapped = r,
              onVote: (_) {},
              onSubmitEdit: (_) {},
              onCancelEdit: () {},
            ),
            extras: MessageExtras(
              reactions: const [
                api.ReactionSummary(
                  emoji: '\u{1F44D}',
                  count: 3,
                  reacted: true,
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('\u{1F44D}'));
      expect(tapped?.emoji, '\u{1F44D}');
      expect(tapped?.reacted, isTrue);
    });
  });

  testWidgets('attachments render through the provider-backed view', (
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
          extras: MessageExtras(
            attachments: const [
              api.Attachment(
                id: 'a1',
                filename: 'notes.txt',
                contentType: 'text/plain',
                size: 2048,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  /// The picker is revealed on hover and opens a floating panel, so reaching the
  /// panel takes the pointer off the row that reveals the button. Six earlier
  /// tests pumped the panel directly and all passed while the feature could not
  /// be used with a mouse at all, so this drives the real pointer path.
  testWidgets('the emoji panel survives the pointer leaving the message row', (
    tester,
  ) async {
    String? picked;
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
            onPickReaction: (e) => picked = e,
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();

    final button = find.byType(EmojiPickerButton);
    expect(button, findsOneWidget, reason: 'hover should reveal the picker');

    await tester.tap(button);
    await tester.pumpAndSettle();
    final panel = find.byType(EmojiPickerPanel);
    expect(panel, findsOneWidget, reason: 'tapping should open the panel');

    /// The failure this exists for: the panel occludes the row, so the pointer
    /// leaves the MouseRegion and the button used to unmount, taking the panel
    /// with it before any tile could be clicked.
    await mouse.moveTo(tester.getCenter(panel));
    await tester.pumpAndSettle();
    expect(
      panel,
      findsOneWidget,
      reason: 'the panel must outlive the pointer leaving the row',
    );

    /// Asserted rather than guarded by an `if`. The old finder looked for an
    /// `InkWell`, which the panel has never rendered - its tiles are
    /// `EmojiGrid` cells - so the guarded block never ran once, and the tap
    /// this test exists to make was never made. Found by its own character,
    /// the way `emoji_picker_test.dart` taps the same grid.
    final tile = find.descendant(of: panel, matching: find.text('\u{1F600}'));
    expect(
      tile,
      findsOneWidget,
      reason: 'the panel must still offer a clickable reaction tile',
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(picked, isNotNull, reason: 'a tile click should report a reaction');
  });

  testWidgets('reactions sit side by side and hug their content, rather than '
      'each taking a whole line', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.reset);

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
          extras: MessageExtras(
            reactions: const [
              api.ReactionSummary(emoji: 'a', count: 1, reacted: false),
              api.ReactionSummary(emoji: 'b', count: 1, reacted: false),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chips = find.byType(AppChip);
    expect(chips, findsNWidgets(2));
    final first = tester.getRect(chips.at(0));
    final second = tester.getRect(chips.at(1));

    // The regression: FocusableTapTarget's hit box had an Align with no size factor, so every chip expanded to the full column width.
    expect(
      first.width,
      lessThan(120),
      reason: 'a reaction chip must hug its emoji and count, not fill the row',
    );
    expect(
      second.top,
      first.top,
      reason: 'two short reactions belong on one line',
    );
    // Not greaterThan: chips now abut at zero gap on purpose, see reaction_chip_gap_test.dart.
    expect(
      second.left,
      greaterThanOrEqualTo(first.right),
      reason: 'the second chip sits beside the first, not under it',
    );
  });
}
