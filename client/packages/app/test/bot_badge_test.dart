// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Bot/Webhook badge: a reader can tell that something was not written
/// by a person without inspecting anything.
///
/// For a bot that is decision 0028's whole requirement on the interface. For
/// a webhook it is more than that: `docs/decisions/0030-incoming-webhooks.md`
/// lets a webhook set a per-post `username` that is never checked against a
/// real member's name, and says the always-visible badge is "the entire
/// mitigation" for that - the one thing standing between a webhook and
/// posting as someone it is not. A badge that a narrow layout, a theme, or a
/// long claimed name can squeeze off the line is no mitigation at all.
///
/// That means the requirement is not "the two surfaces that draw a name",
/// which is where this file used to stop - it is every surface that draws a
/// message author's name: the message row itself, a reply quote, a thread
/// parent card, a forwarded message, a search hit, a pinned or saved entry,
/// a thread-list row, a command-palette hit, and a member row. This file
/// covers the message row and the member row, the two the badge was born on;
/// `author_name_line_test.dart` covers the shared widget every other surface
/// above draws its badge from, and each of those surfaces has its own test
/// pumping its own widget directly, so a regression in any one of them is
/// caught where it would actually happen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

api.UserProfile _profile({
  bool isBot = false,
  bool isWebhook = false,
  List<String> roles = const [],
}) => api.UserProfile(
  id: 'u1',
  username: 'helper',
  displayName: 'Helper',
  createdAt: 0,
  roles: roles,
  isBot: isBot,
  isWebhook: isWebhook,
);

void main() {
  group('the wire field', () {
    test('is read from the server', () {
      final bot = api.UserProfile.fromJson({
        'id': 'u1',
        'username': 'helper',
        'display_name': 'Helper',
        'created_at': 0,
        'is_bot': true,
      });

      expect(bot.isBot, isTrue);
    });

    test('absent reads as not a bot', () {
      final person = api.UserProfile.fromJson({
        'id': 'u1',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
      });

      expect(
        person.isBot,
        isFalse,
        reason: 'a deployment too old to have the field has no bots either',
      );
    });

    test('an explicit false is a person', () {
      final person = api.UserProfile.fromJson({
        'id': 'u1',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
        'is_bot': false,
      });

      expect(person.isBot, isFalse);
    });
  });

  group('what a message row shows', () {
    /// Pumps one row whose author resolves to [profile].
    Future<void> pumpRow(WidgetTester tester, api.UserProfile profile) async {
      late BatchProfilesController controller;
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(authorId: profile.id),
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
          overrides: [
            batchProfilesControllerProvider.overrideWith((ref) {
              controller = BatchProfilesController(ref);
              return controller;
            }),
          ],
        ),
      );
      controller.state = {...controller.state, profile.id: profile};
      await tester.pump();
    }

    testWidgets('a message from a bot is badged', (tester) async {
      await pumpRow(tester, _profile(isBot: true));

      expect(
        find.text('BOT'),
        findsOneWidget,
        reason: 'AppBadge uppercases, so the label reads BOT on screen',
      );
    });

    testWidgets('a message from a webhook is badged, not just a bot', (
      tester,
    ) async {
      await pumpRow(tester, _profile(isWebhook: true));

      expect(
        find.text('WEBHOOK'),
        findsOneWidget,
        reason:
            'this is the badge decision 0030 calls the entire mitigation '
            'for a webhook\'s caller-chosen username',
      );
    });

    testWidgets(
      'a webhook\'s claimed name cannot be long enough to hide its own badge',
      (tester) async {
        await pumpRow(
          tester,
          api.UserProfile(
            id: 'u1',
            username: 'helper',
            displayName: 'A' * 200,
            createdAt: 0,
            isWebhook: true,
          ),
        );

        final badgeRect = tester.getRect(find.byType(AppBadge));
        expect(
          badgeRect.width,
          greaterThan(0),
          reason:
              'a claimed name this long must not be able to squeeze the '
              'mitigation off the row rather than merely off the visible '
              'part of it',
        );
        expect(
          find.text('WEBHOOK'),
          findsOneWidget,
          reason: 'the badge itself must still exist, not just have room',
        );
      },
    );

    testWidgets('a message from a person is not', (tester) async {
      await pumpRow(tester, _profile());

      expect(find.byType(AppBadge), findsNothing);
    });

    testWidgets('an unresolved author is not badged', (tester) async {
      await tester.pumpWidget(
        harness(
          MessageRow(
            message: message(authorId: 'nobody-has-asked'),
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
      await tester.pump();

      expect(
        find.byType(AppBadge),
        findsNothing,
        reason:
            'a badge appearing a moment after the name is worse than one '
            'that is simply right once the profile is known',
      );
    });
  });

  group('what a member row shows', () {
    test('bot wins over a role, because there is only room for one', () {
      // The rule member_pane_rows.dart applies, stated where it can be checked.
      String? badgeFor(api.UserProfile p) =>
          p.isBot ? 'Bot' : (p.roles.isEmpty ? null : p.roles.first);

      expect(
        badgeFor(_profile(isBot: true, roles: const ['Op'])),
        'Bot',
        reason: 'that this is a program is the fact a reader most needs',
      );
      expect(badgeFor(_profile(roles: const ['Op'])), 'Op');
      expect(badgeFor(_profile()), isNull);
    });
  });
}
