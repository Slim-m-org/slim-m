// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply's context line, measured: the quote sits above the author line, and
/// a hooked connector joins the reply's own avatar to it.
///
/// Every geometry assertion runs at a phone and a desktop width and at both
/// avatar steps of the message density setting, because the connector is
/// derived from the avatar size and a layout that only fits one passes a
/// single-size check.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_elbow.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _widths = [390.0, 1280.0];
const _densities = [AppDensity.compact, AppDensity.normal];

class _Density extends MessageDensityController {
  _Density(super.ref, AppDensity density) {
    state = density;
  }
}

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

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  AppDensity density = AppDensity.normal,
  Message? parent,
  bool noParent = false,
  bool mentionsMe = false,
  VoidCallback? onReplyTap,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    harness(
      Align(
        alignment: Alignment.topLeft,
        child: MessageRow(
          message: _reply,
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          replyTo: noParent
              ? null
              : parent ??
                    message(
                      id: 'p',
                      authorId: 'author-1',
                      authorDisplayName: 'Matthew',
                      content: 'why is this app 189 MB',
                    ),
          extras: MessageExtras(mentionsMe: mentionsMe),
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
      overrides: [
        messageDensityControllerProvider.overrideWith(
          (ref) => _Density(ref, density),
        ),
        ...overrides,
      ],
    ),
  );
  await tester.pump();
}

Rect _quote(WidgetTester t) => t.getRect(find.byType(ReplyQuote));

Rect _header(WidgetTester t) => t.getRect(find.byType(MessageRowHeader));

Rect _avatar(WidgetTester t) => t.getRect(
  find.descendant(
    of: find.byType(MessageRowLeading),
    matching: find.byType(AppAvatar),
  ),
);

Rect _elbow(WidgetTester t) => t.getRect(find.byKey(ReplyElbow.lineKey));

ReplyElbowGeometry _geometry(WidgetTester t) =>
    (t.widget<CustomPaint>(find.byKey(ReplyElbow.lineKey)).painter!
            as ReplyElbowPainter)
        .geometry;

void main() {
  for (final width in _widths) {
    for (final density in _densities) {
      final at = '${width.toInt()} wide, ${density.name} density';

      group(at, () {
        testWidgets('the quote row sits above the author line, in the '
            'content column', (tester) async {
          await _pump(tester, width: width, density: density);
          final quote = _quote(tester);
          final header = _header(tester);
          expect(quote.bottom, lessThanOrEqualTo(header.top));
          expect(quote.left, header.left);
          expect(
            quote.height,
            lessThanOrEqualTo(AppSizes.rowPointer),
            reason: 'a one-line quote, not a card',
          );
          expect(find.textContaining('Matthew'), findsOneWidget);
          expect(find.textContaining('why is this app'), findsOneWidget);
        });

        testWidgets('the reply keeps its own avatar and name, level with each '
            'other', (tester) async {
          await _pump(tester, width: width, density: density);
          expect(find.byType(MessageRowHeader), findsOneWidget);
          expect(find.text('Nick'), findsWidgets);
          expect(_avatar(tester).width, density.avatarSize);
          expect(_avatar(tester).top, closeTo(_header(tester).top, 0.01));
        });

        testWidgets('the connector leaves the avatar column and ends at the '
            'quote row', (tester) async {
          await _pump(tester, width: width, density: density);
          final avatar = _avatar(tester);
          final quote = _quote(tester);
          final elbow = _elbow(tester);
          final geometry = _geometry(tester);

          expect(elbow.left, avatar.left);
          expect(elbow.right, quote.left, reason: 'the column ends at text');
          expect(elbow.bottom, avatar.top);

          final tail = elbow.topLeft + geometry.tail;
          expect(tail.dx, closeTo(avatar.center.dx, 0.01));
          expect(tail.dy, closeTo(avatar.top, 0.01));

          final tip = elbow.topLeft + geometry.tip;
          expect(tip.dx, lessThan(quote.left));
          expect(tip.dx, closeTo(quote.left - ReplyElbow.tipGap, 0.01));
          expect(tip.dy, closeTo(quote.center.dy, 0.01));
        });

        testWidgets('the connector is a 2dp stroke in the border token', (
          tester,
        ) async {
          await _pump(tester, width: width, density: density);
          expect(
            find.byKey(ReplyElbow.lineKey),
            paints..path(
              color: AppTokens.light.borderSubtle,
              strokeWidth: 2,
              style: PaintingStyle.stroke,
            ),
          );
        });

        testWidgets('nothing overlaps, even with a long name and a long '
            'quote', (tester) async {
          await _pump(
            tester,
            width: width,
            density: density,
            parent: message(
              id: 'p',
              authorDisplayName: 'Christoph Bartholomew Fitzgerald-Huang III',
              content: List.filled(60, 'wandering').join(' '),
            ),
          );
          expect(tester.takeException(), isNull);
          final quote = _quote(tester);
          expect(quote.overlaps(_header(tester)), isFalse);
          expect(quote.overlaps(_avatar(tester)), isFalse);
          expect(_elbow(tester).overlaps(quote), isFalse);
          expect(_elbow(tester).overlaps(_header(tester)), isFalse);
          expect(quote.right, lessThanOrEqualTo(width));
        });
      });
    }
  }

  group('the quote', () {
    testWidgets('tapping it jumps to the parent', (tester) async {
      var jumps = 0;
      await _pump(tester, width: 390, onReplyTap: () => jumps++);
      await tester.tap(find.textContaining('why is this app'));
      expect(jumps, 1);
    });

    testWidgets('tapping the little avatar jumps too', (tester) async {
      var jumps = 0;
      await _pump(tester, width: 1280, onReplyTap: () => jumps++);
      final avatar = find.descendant(
        of: find.byType(ReplyQuote),
        matching: find.byType(AppAvatar),
      );
      expect(tester.getSize(avatar).width, AppAvatarSize.s16);
      await tester.tap(avatar);
      expect(jumps, 1);
    });

    testWidgets('the parent author is drawn as a 16dp avatar', (tester) async {
      await _pump(tester, width: 390);
      final avatar = find.descendant(
        of: find.byType(ReplyQuote),
        matching: find.byType(AppAvatar),
      );
      expect(avatar, findsOneWidget);
      expect(tester.getSize(avatar), const Size(16, 16));
    });

    testWidgets('a pinged reply names the author with an @', (tester) async {
      await _pump(
        tester,
        width: 390,
        mentionsMe: true,
        parent: message(
          id: 'p',
          authorId: 'me',
          authorDisplayName: 'Me Myself',
        ),
        overrides: [
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'me',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 99999999999999,
              ),
            ),
          ),
        ],
      );
      expect(find.textContaining('@Me Myself'), findsOneWidget);
    });

    testWidgets('a parent that is not loaded gets an honest placeholder', (
      tester,
    ) async {
      await _pump(tester, width: 390, noParent: true);
      expect(find.text('Message unavailable'), findsOneWidget);
      final quote = find.byType(ReplyQuote);
      expect(
        find.descendant(of: quote, matching: find.byType(AppAvatar)),
        findsNothing,
        reason: 'there is nobody to draw',
      );
      expect(_quote(tester).bottom, lessThanOrEqualTo(_header(tester).top));
      expect(find.byKey(ReplyElbow.lineKey), findsOneWidget);
    });

    testWidgets('tapping the placeholder still jumps', (tester) async {
      var jumps = 0;
      await _pump(
        tester,
        width: 390,
        noParent: true,
        onReplyTap: () => jumps++,
      );
      await tester.tap(find.text('Message unavailable'));
      expect(jumps, 1);
    });

    testWidgets('a screen reader hears a tappable reply to the author', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);
      await _pump(tester, width: 390);
      final node = tester.getSemantics(find.byType(ReplyQuote));
      expect(node.label, 'Reply to Matthew: why is this app 189 MB');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    });

    testWidgets('a deleted parent is announced without a name', (tester) async {
      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);
      await _pump(tester, width: 390, noParent: true);
      expect(
        tester.getSemantics(find.byType(ReplyQuote)).label,
        'Reply to a message that is not available',
      );
    });
  });
}
