// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The forwarded-message container, and the access check hiding inside it.
///
/// The server sends a forward's origin channel as an id and never a name, so
/// what a reader is told about where a forward came from is decided entirely
/// by whether their own channel cache can name it. A channel this client does
/// not hold is one the reader cannot see, and the card must then show no
/// location and offer no jump - not a label they were never entitled to, and
/// not a tap that would only be refused.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/widgets/forwarded_message_card.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _forwarded = ForwardedMessage(
  messageId: 'm-origin',
  channelId: 'c-origin',
  authorId: 'u-alice',
  authorDisplayName: 'Alice',
  authorAvatarUpdatedAt: null,
  createdAt: 0,
  content: 'the original text',
);

Channel _channel({required String name, String? dmParticipantId}) => Channel(
  id: 'c-origin',
  name: name,
  kind: 'text',
  createdAt: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: dmParticipantId,
  position: 0,
);

/// [origin] is what this client's channel cache holds for the forward's
/// origin - null for a channel it does not hold at all.
Future<void> _pump(WidgetTester tester, {Channel? origin}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        channelByIdProvider(
          'c-origin',
        ).overrideWith((ref) => Stream.value(origin)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: ForwardedMessageCard(
            forwarded: _forwarded,
            body: Text('the original text'),
            attachments: [],
            currentChannelId: 'c-here',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('draws the original author, its own text, and where it came '
      'from', (tester) async {
    await _pump(tester, origin: _channel(name: 'general'));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('the original text'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
  });

  testWidgets('a DM origin is named by the person, never prefixed like a '
      'channel', (tester) async {
    await _pump(
      tester,
      origin: _channel(name: 'Priya', dmParticipantId: 'u-priya'),
    );

    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('#Priya'), findsNothing);
  });

  testWidgets('an origin this client does not hold shows no location and no '
      'jump', (tester) async {
    await _pump(tester);

    expect(
      find.text('the original text'),
      findsOneWidget,
      reason:
          'what was forwarded is still shown; only where it came from is not',
    );
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('#general'), findsNothing);
    expect(
      find.byType(InkWell),
      findsNothing,
      reason: 'no tap target at all, rather than one that would be refused',
    );
  });

  testWidgets('a reachable origin is announced as one that can be opened', (
    tester,
  ) async {
    await _pump(tester, origin: _channel(name: 'general'));

    expect(find.byType(InkWell), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Forwarded message from Alice in #general')),
      findsOneWidget,
    );
  });

  testWidgets("a forwarded webhook post keeps its badge, and its claimed name "
      'cannot push it off a phone-width row', (tester) async {
    late BatchProfilesController controller;
    const longClaim =
        'Definitely A Real Person Definitely A Real Person '
        'Definitely A Real Person';
    const forwardedFromWebhook = ForwardedMessage(
      messageId: 'm-origin',
      channelId: 'c-origin',
      authorId: 'webhook-1',
      authorDisplayName: longClaim,
      authorAvatarUpdatedAt: null,
      createdAt: 0,
      content: 'the disk is nearly full',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          channelByIdProvider(
            'c-origin',
          ).overrideWith((ref) => Stream.value(_channel(name: 'general'))),
          batchProfilesControllerProvider.overrideWith((ref) {
            controller = BatchProfilesController(ref);
            return controller;
          }),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: ForwardedMessageCard(
                forwarded: forwardedFromWebhook,
                body: const Text('the disk is nearly full'),
                attachments: const [],
                currentChannelId: 'c-here',
              ),
            ),
          ),
        ),
      ),
    );
    controller.state = {
      'webhook-1': const api.UserProfile(
        id: 'webhook-1',
        username: 'alerts',
        displayName: longClaim,
        createdAt: 0,
        isWebhook: true,
      ),
    };
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('WEBHOOK'),
      findsOneWidget,
      reason:
          'docs/decisions/0030 calls this badge the entire mitigation for '
          "a webhook's claimed name",
    );
    expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));
  });

  testWidgets('what was forwarded stays readable to a screen reader', (
    tester,
  ) async {
    await _pump(tester, origin: _channel(name: 'general'));

    // The header collapses to one sentence; what was forwarded must survive into the announcement with it.
    final node = tester.getSemantics(find.text('the original text'));
    expect(node.label, contains('Forwarded message from Alice in #general'));
    expect(node.label, contains('the original text'));
  });

  testWidgets('a forward whose original was deleted says so and shows no '
      'author or text', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: ForwardedMessageCard(
              forwarded: ForwardedMessage(
                messageId: 'm-origin',
                channelId: 'c-origin',
                createdAt: 0,
                content: '',
                removed: true,
              ),
              body: null,
              attachments: [],
              currentChannelId: 'c-here',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Original message was deleted'), findsOneWidget);
    expect(find.text('Unknown user'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });
}
