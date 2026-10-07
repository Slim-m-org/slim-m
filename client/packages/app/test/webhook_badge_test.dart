// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Webhook badge: a reader can tell that something was written by a
/// webhook without inspecting anything - decision 0030's whole requirement,
/// mirroring what `bot_badge_test.dart` already proves for `isBot`.
///
/// `isWebhook` is resolved from the author's profile exactly the way `isBot`
/// is (`resolution.profile?.isWebhook`), not passed in from outside: a
/// webhook never appears in the member list, so the message row is the one
/// place this ever has to be true.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

api.UserProfile _profile({bool isWebhook = false}) => api.UserProfile(
  id: 'w1',
  username: 'webhook-w1',
  displayName: 'CI Bot',
  createdAt: 0,
  isWebhook: isWebhook,
);

void main() {
  group('the wire field', () {
    test('is read from the server', () {
      final webhook = api.UserProfile.fromJson({
        'id': 'w1',
        'username': 'webhook-w1',
        'display_name': 'CI Bot',
        'created_at': 0,
        'is_webhook': true,
      });

      expect(webhook.isWebhook, isTrue);
    });

    test('absent reads as not a webhook', () {
      final person = api.UserProfile.fromJson({
        'id': 'u1',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
      });

      expect(
        person.isWebhook,
        isFalse,
        reason: 'a deployment too old to have the field has no webhooks either',
      );
    });

    test('an explicit false is a person', () {
      final person = api.UserProfile.fromJson({
        'id': 'u1',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
        'is_webhook': false,
      });

      expect(person.isWebhook, isFalse);
    });
  });

  group('what a message row shows', () {
    /// Pumps one row whose author resolves to [profile].
    Future<void> pumpRow(
      WidgetTester tester,
      api.UserProfile profile, {
      String? webhookUsername,
    }) async {
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
            extras: MessageExtras(webhookUsername: webhookUsername),
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

    testWidgets(
      'a webhook row shows a code-box leading glyph and the tag badge',
      (tester) async {
        await pumpRow(tester, _profile(isWebhook: true));

        expect(find.byType(AppAvatar), findsNothing);
        expect(
          find.text('WEBHOOK'),
          findsOneWidget,
          reason: 'AppBadge uppercases, so the label reads WEBHOOK on screen',
        );
        expect(find.text('CI Bot'), findsOneWidget);
      },
    );

    testWidgets('a webhook post shows its own username beside the badge', (
      tester,
    ) async {
      await pumpRow(
        tester,
        _profile(isWebhook: true),
        webhookUsername: 'Grafana',
      );

      expect(find.text('Grafana'), findsOneWidget);
      expect(find.text('CI Bot'), findsNothing);
      expect(
        find.text('WEBHOOK'),
        findsOneWidget,
        reason: 'the badge stays so the label cannot pass as a real member',
      );
    });

    testWidgets('a username label on a real member is ignored', (tester) async {
      await pumpRow(tester, _profile(), webhookUsername: 'Grafana');

      expect(find.text('Grafana'), findsNothing);
      expect(find.text('CI Bot'), findsOneWidget);
    });

    testWidgets('a message from a person is not badged', (tester) async {
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
}
