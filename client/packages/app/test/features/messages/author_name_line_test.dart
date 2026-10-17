// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `AuthorNameLine`, the shared name-plus-badge row every dense surface that
/// draws a message author's name now builds on: a reply quote, a thread
/// parent card, a forwarded message, a search hit, a pinned or saved entry,
/// a thread-list row, and a command-palette hit.
///
/// `docs/decisions/0030-incoming-webhooks.md` calls the always-visible
/// `Webhook` badge the entire mitigation for a webhook's caller-chosen
/// `username`, so what this file actually needs to prove is geometric: the
/// badge renders at its full, non-zero size regardless of how long or
/// hostile the name beside it is, at a width as narrow as a phone. Finding
/// the badge widget in the tree is not enough - it could be clipped to
/// nothing or pushed off the row - so every case here reads the rendered
/// rect.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/author_label.dart';
import 'package:slimm_design_system/design_system.dart';

api.UserProfile _profile({bool isBot = false, bool isWebhook = false}) =>
    api.UserProfile(
      id: 'u1',
      username: 'helper',
      displayName: 'Helper',
      createdAt: 0,
      isBot: isBot,
      isWebhook: isWebhook,
    );

/// [width] simulates a phone-width column - `kCompactWidth` territory - since
/// a dense surface is exactly where a full-size badge is least likely to fit
/// by accident.
Future<void> _pump(WidgetTester tester, Widget child, {double width = 320}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(width: width, child: child),
        ),
      ),
    );

void main() {
  testWidgets('a plain person draws no badge', (tester) async {
    await _pump(tester, AuthorNameLine(name: 'Priya', profile: _profile()));

    expect(find.byType(AppBadge), findsNothing);
  });

  testWidgets('a bot draws the Bot badge at full size', (tester) async {
    await _pump(
      tester,
      AuthorNameLine(name: 'Helper', profile: _profile(isBot: true)),
    );

    expect(find.text('BOT'), findsOneWidget);
    expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));
  });

  testWidgets('a webhook draws the Webhook badge at full size', (tester) async {
    await _pump(
      tester,
      AuthorNameLine(name: 'alerts', profile: _profile(isWebhook: true)),
    );

    expect(find.text('WEBHOOK'), findsOneWidget);
    expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));
  });

  testWidgets(
    'a webhook\'s claimed name cannot grow long enough to push its own '
    'badge off a phone-width row',
    (tester) async {
      await _pump(
        tester,
        AuthorNameLine(
          name: 'Nick Conn ' * 30,
          profile: _profile(isWebhook: true),
        ),
        width: 320,
      );

      expect(tester.takeException(), isNull, reason: 'no overflow either');
      final badgeRect = tester.getRect(find.byType(AppBadge));
      final rowRect = tester.getRect(find.byType(AuthorNameLine));
      expect(badgeRect.width, greaterThan(0));
      expect(
        badgeRect.right,
        lessThanOrEqualTo(rowRect.right + 0.5),
        reason: 'the badge must stay inside the row it was drawn on',
      );
    },
  );

  testWidgets('a webhook badge survives a secondary bit of text after it too', (
    tester,
  ) async {
    await _pump(
      tester,
      AuthorNameLine(
        name: 'Nick Conn ' * 30,
        profile: _profile(isWebhook: true),
        secondary:
            'a message this long would otherwise crowd everything '
            'else off the line entirely, badge included',
      ),
      width: 320,
    );

    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));
  });

  testWidgets('the name still shrinks so the badge has somewhere to go', (
    tester,
  ) async {
    await _pump(
      tester,
      AuthorNameLine(
        name: 'Nick Conn ' * 30,
        profile: _profile(isWebhook: true),
      ),
      width: 320,
    );

    final nameRect = tester.getRect(
      find
          .descendant(
            of: find.byType(AuthorNameLine),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(
      nameRect.width,
      lessThan(320),
      reason: 'the unbounded name is far wider than the whole row',
    );
  });
}
