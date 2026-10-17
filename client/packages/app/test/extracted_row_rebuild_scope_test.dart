// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The same measurement `message_row_unrelated_profile_rebuild_test.dart`
/// applies to `MessageRowHeader`/`MessageRowLeading`, extended to the four
/// list rows that were later split out of their parent `itemBuilder`s for the
/// same reason: `SearchResultRow`, `ThreadRow`, `PinnedMessageRow` and
/// `PaletteMessageAuthor` each select only their own author's slice of
/// `batchProfilesControllerProvider`, so an unrelated author resolving must
/// rebuild none of them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/channel_search.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart';
import 'package:slimm_app/src/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/widgets/threads_sheet.dart';

import 'message_row_harness.dart';

/// How many times a widget of type [T] was rebuilt while [action] ran; the
/// same helper `message_row_unrelated_profile_rebuild_test.dart` defines.
Future<int> _rebuildsOf<T extends Widget>(
  Future<void> Function() action,
) async {
  var count = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget.runtimeType == T) count++;
  };
  try {
    await action();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return count;
}

api.Message _apiMessage({
  String id = 'm1',
  String? authorId = 'author-1',
  String? authorDisplayName = 'Priya',
}) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorDisplayName,
  seq: 5,
  content: 'hello there',
  createdAt: 1700000000000,
  editedAt: null,
);

Future<void> _resolveUnrelatedAuthor(
  WidgetTester tester,
  BatchProfilesController controller,
) async {
  controller.state = {
    ...controller.state,
    'someone-else': const api.UserProfile(
      id: 'someone-else',
      username: 'someone-else',
      displayName: 'Someone Else',
      createdAt: 0,
    ),
  };
  await tester.pump();
}

void main() {
  testWidgets(
    "an unrelated author resolving does not rebuild a search hit's row",
    (tester) async {
      late BatchProfilesController controller;
      await tester.pumpWidget(
        harness(
          SearchResultRow(
            message: _apiMessage(),
            knownUsernames: const {},
            customEmoji: const {},
            onSelect: (_) {},
          ),
          overrides: [
            batchProfilesControllerProvider.overrideWith((ref) {
              controller = BatchProfilesController(ref);
              return controller;
            }),
          ],
        ),
      );
      await tester.pump();

      final rebuilds = await _rebuildsOf<SearchResultRow>(
        () => _resolveUnrelatedAuthor(tester, controller),
      );

      expect(
        rebuilds,
        0,
        reason:
            "a row must only rebuild when its own author's entry "
            'changes, never when an unrelated id resolves',
      );
    },
  );

  testWidgets(
    "an unrelated author resolving does not rebuild a thread sheet's row",
    (tester) async {
      late BatchProfilesController controller;
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        harness(
          ThreadRow(
            thread: const api.ThreadListItem(
              id: 't1',
              parentMessageId: 'm1',
              parentContent: 'the original message',
              parentAuthorId: 'author-1',
              parentAuthorDisplayName: 'Priya',
              createdAt: 0,
              replyCount: 2,
              lastReplyAt: 1,
              unreadCount: 0,
            ),
            router: router,
          ),
          overrides: [
            batchProfilesControllerProvider.overrideWith((ref) {
              controller = BatchProfilesController(ref);
              return controller;
            }),
          ],
        ),
      );
      await tester.pump();

      final rebuilds = await _rebuildsOf<ThreadRow>(
        () => _resolveUnrelatedAuthor(tester, controller),
      );

      expect(
        rebuilds,
        0,
        reason:
            "a row must only rebuild when its own author's entry "
            'changes, never when an unrelated id resolves',
      );
    },
  );

  testWidgets(
    'an unrelated author resolving does not rebuild a pinned message row',
    (tester) async {
      late BatchProfilesController controller;
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        harness(
          PinnedMessageRow(
            channelId: 'c1',
            pin: api.PinnedMessage(
              message: _apiMessage(),
              pinnedAt: 0,
              pinnedBy: 'author-1',
            ),
            router: router,
            currentChannelId: 'c1',
          ),
          overrides: [
            batchProfilesControllerProvider.overrideWith((ref) {
              controller = BatchProfilesController(ref);
              return controller;
            }),
          ],
        ),
      );
      await tester.pump();

      final rebuilds = await _rebuildsOf<PinnedMessageRow>(
        () => _resolveUnrelatedAuthor(tester, controller),
      );

      expect(
        rebuilds,
        0,
        reason:
            "a row must only rebuild when its own author's entry "
            'changes, never when an unrelated id resolves',
      );
    },
  );

  testWidgets(
    "an unrelated author resolving does not rebuild the palette's message "
    'author label',
    (tester) async {
      late BatchProfilesController controller;
      await tester.pumpWidget(
        harness(
          const PaletteMessageAuthor(
            authorId: 'author-1',
            cachedDisplayName: 'Priya',
          ),
          overrides: [
            batchProfilesControllerProvider.overrideWith((ref) {
              controller = BatchProfilesController(ref);
              return controller;
            }),
          ],
        ),
      );
      await tester.pump();

      final rebuilds = await _rebuildsOf<PaletteMessageAuthor>(
        () => _resolveUnrelatedAuthor(tester, controller),
      );

      expect(
        rebuilds,
        0,
        reason:
            "a row must only rebuild when its own author's entry "
            'changes, never when an unrelated id resolves',
      );
    },
  );
}
