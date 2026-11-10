// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reply strip inside a real row: how far a finger reaches below the
/// quote at touch density, and how much room the quote keeps beside the hover
/// toolbar in a narrow pane.
///
/// `desktop-vs-mobile.md` law 2 and law 1: the reach follows the window width,
/// and so does the toolbar's reserve, which a 360dp pane inside a wide window
/// still gets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _reply = Message(
  id: 'r1',
  channelId: 'c1',
  authorId: 'author-2',
  authorDisplayName: 'Nick',
  seq: 6,
  content: 'because i cannot compress your packages',
  createdAt: 1700000001000,
  replyToId: 'p',
  pending: false,
  failed: false,
);

/// Wide enough for the parent's name and a readable run of its text.
const _readableQuote = 240.0;

final _longSnippet = List.filled(40, 'wandering').join(' ');

const _webhook = api.UserProfile(
  id: 'webhook-1',
  username: 'alerts',
  displayName: 'Alerts Service',
  createdAt: 0,
  isWebhook: true,
);

Future<void> _pump(
  WidgetTester tester, {
  required double window,
  double? pane,
  Message? parent,
  api.UserProfile? parentProfile,
  VoidCallback? onReplyTap,
}) async {
  tester.view.physicalSize = Size(window, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BatchProfilesController profiles;
  await tester.pumpWidget(
    harness(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: pane ?? window,
          child: MessageRow(
            message: _reply,
            grouped: false,
            showNewDivider: false,
            knownUsernames: const {},
            actions: noActions,
            editing: false,
            replyTo:
                parent ??
                message(
                  id: 'p',
                  authorId: 'author-1',
                  authorDisplayName: 'Matthew',
                  content: _longSnippet,
                ),
            callbacks: MessageRowCallbacks(
              onRetry: noop,
              onDiscard: noop,
              onPickReaction: (_) {},
              onReactionTap: (_) {},
              onVote: (_) {},
              onSubmitEdit: (_) {},
              onCancelEdit: noop,
              onReplyTap: onReplyTap ?? noop,
            ),
          ),
        ),
      ),
      overrides: [
        batchProfilesControllerProvider.overrideWith((ref) {
          profiles = BatchProfilesController(ref);
          return profiles;
        }),
      ],
    ),
  );
  if (parentProfile != null) {
    profiles.state = {parentProfile.id: parentProfile};
  }
  await tester.pump();
}

Rect _quote(WidgetTester t) => t.getRect(find.byKey(ReplyQuote.quoteKey));

Rect _header(WidgetTester t) =>
    t.getRect(find.byKey(MessageRowHeader.headerKey));

void main() {
  group('a finger under the quote', () {
    for (final below in const [
      4.0,
      12.0,
      20.0,
      22.0,
      23.0,
      24.0,
      26.0,
      32.0,
      38.0,
      42.0,
    ]) {
      testWidgets('jumps ${below.toInt()}dp below its top on a phone', (
        tester,
      ) async {
        var jumps = 0;
        await _pump(tester, window: 390, onReplyTap: () => jumps++);
        final quote = _quote(tester);
        // The author name sits under the quote, so this press is over it.
        final overName = _header(tester).left + 4;
        await tester.tapAt(Offset(overName, quote.top + below));
        expect(jumps, 1);
      });
    }

    testWidgets('stops at the 44dp touch floor', (tester) async {
      var jumps = 0;
      await _pump(tester, window: 390, onReplyTap: () => jumps++);
      final quote = _quote(tester);
      await tester.tapAt(
        Offset(_header(tester).left + 4, quote.top + AppSizes.rowTouch + 1),
      );
      expect(jumps, 0);
    });

    testWidgets('gets no invisible reach on a wide window', (tester) async {
      var jumps = 0;
      await _pump(tester, window: 1280, onReplyTap: () => jumps++);
      final quote = _quote(tester);
      await tester.tapAt(Offset(_header(tester).left + 4, quote.top + 30));
      expect(jumps, 0);
    });
  });

  group('the quote beside the hover toolbar', () {
    testWidgets('keeps a readable width in a 360dp pane of a wide window', (
      tester,
    ) async {
      await _pump(tester, window: 1280, pane: 360);
      expect(_quote(tester).width, greaterThanOrEqualTo(_readableQuote));
    });

    testWidgets('does not overflow for a webhook parent in a 360dp pane', (
      tester,
    ) async {
      await _pump(
        tester,
        window: 1280,
        pane: 360,
        parentProfile: _webhook,
        parent: message(
          id: 'p',
          authorId: 'webhook-1',
          authorDisplayName: 'Alerts Service',
          content: 'the disk is nearly full',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('WEBHOOK'), findsOneWidget);
    });

    testWidgets('stops short of the toolbar where the pane is wide', (
      tester,
    ) async {
      await _pump(tester, window: 1280, pane: 700);
      final row = tester.getRect(find.byKey(MessageRow.hoverFillKey));
      final reserve = MessageHoverToolbar.clearance(compact: false).right;
      expect(
        _quote(tester).right,
        lessThanOrEqualTo(row.right - AppSizes.paneGutter - reserve),
        reason: 'a long quote must not run under the hover toolbar',
      );
    });
  });
}
