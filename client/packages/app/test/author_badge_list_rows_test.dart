// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five list-row surfaces `extracted_row_rebuild_scope_test.dart` names,
/// plus `SavedMessageRow` alongside them: each draws a message author's name
/// and, before this, drew no `AuthorNameLine` and so no badge at all - a
/// search hit, a thread-list row, a pinned entry, a saved entry, and a
/// command-palette hit.
///
/// `docs/decisions/0030-incoming-webhooks.md` calls the badge the entire
/// mitigation for a webhook's caller-chosen `username`, so each case here
/// pumps the row directly (the same technique
/// `extracted_row_rebuild_scope_test.dart` already uses) with a webhook
/// profile and reads the badge's rendered rect - finding the widget alone
/// would pass even if it were clipped to nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_app/src/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/widgets/saved_messages_sheet.dart';
import 'package:slimm_app/src/widgets/threads_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _webhookId = 'webhook-1';
final _longClaimedName = 'Definitely A Real Person ' * 8;

final _webhookProfile = api.UserProfile(
  id: _webhookId,
  username: 'alerts',
  displayName: _longClaimedName,
  createdAt: 0,
  isWebhook: true,
);

api.Message _apiMessage() => api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: _webhookId,
  authorDisplayName: _longClaimedName,
  seq: 5,
  content: 'the disk is nearly full',
  createdAt: 0,
  editedAt: null,
);

/// Pumps [child] with a `batchProfilesControllerProvider` already resolved
/// to the webhook profile, and any extra [overrides] a particular row needs.
Future<void> _pumpResolved(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
}) async {
  late BatchProfilesController controller;
  await tester.pumpWidget(
    harness(
      child,
      overrides: [
        batchProfilesControllerProvider.overrideWith((ref) {
          controller = BatchProfilesController(ref);
          return controller;
        }),
        ...overrides,
      ],
    ),
  );
  controller.state = {...controller.state, _webhookProfile.id: _webhookProfile};
  await tester.pump();
}

void _expectFullSizeBadge(WidgetTester tester) {
  expect(find.text('WEBHOOK'), findsOneWidget);
  expect(
    tester.getRect(find.byType(AppBadge)).width,
    greaterThan(0),
    reason: 'a claimed name this long must not squeeze the badge to nothing',
  );
}

void main() {
  testWidgets('a webhook search hit is badged', (tester) async {
    await _pumpResolved(
      tester,
      SearchResultRow(
        message: _apiMessage(),
        knownUsernames: const {},
        customEmoji: const {},
        onSelect: (_) {},
      ),
    );

    _expectFullSizeBadge(tester);
  });

  testWidgets('a webhook thread-list row is badged', (tester) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
    );
    addTearDown(router.dispose);

    await _pumpResolved(
      tester,
      ThreadRow(
        thread: api.ThreadListItem(
          id: 't1',
          parentMessageId: 'm1',
          parentContent: 'the disk is nearly full',
          parentAuthorId: _webhookId,
          parentAuthorDisplayName: _longClaimedName,
          createdAt: 0,
          replyCount: 0,
          lastReplyAt: null,
          unreadCount: 0,
        ),
        router: router,
      ),
    );

    _expectFullSizeBadge(tester);
  });

  testWidgets('a webhook pinned entry is badged', (tester) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
    );
    addTearDown(router.dispose);

    await _pumpResolved(
      tester,
      PinnedMessageRow(
        channelId: 'c1',
        pin: api.PinnedMessage(
          message: _apiMessage(),
          pinnedAt: 0,
          pinnedBy: _webhookId,
        ),
        router: router,
        currentChannelId: 'c1',
      ),
    );

    _expectFullSizeBadge(tester);
  });

  testWidgets('a webhook saved entry is badged', (tester) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
    );
    addTearDown(router.dispose);

    await _pumpResolved(
      tester,
      SavedMessageRow(
        saved: api.SavedMessage(message: _apiMessage(), savedAt: 0),
        router: router,
        currentChannelId: 'c1',
      ),
      overrides: [
        channelByIdProvider('c1').overrideWith((ref) => Stream.value(null)),
      ],
    );

    _expectFullSizeBadge(tester);
  });

  testWidgets('a webhook hit in the command palette is badged', (tester) async {
    await _pumpResolved(
      tester,
      PaletteMessageAuthor(
        authorId: _webhookId,
        cachedDisplayName: _longClaimedName,
      ),
    );

    _expectFullSizeBadge(tester);
  });
}
