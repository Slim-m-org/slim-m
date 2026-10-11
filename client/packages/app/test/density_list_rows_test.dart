// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0062 follow-up: search hits, the thread parent card and the pinned,
/// saved and threads sheet rows follow the message density, asserted as the
/// measured size of each row rather than that a widget is present.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/display_density.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/channel_search.dart';
import 'package:slimm_app/src/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/widgets/saved_messages_sheet.dart';
import 'package:slimm_app/src/widgets/thread_parent_card.dart';
import 'package:slimm_app/src/widgets/threads_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _message = api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'author-1',
  authorDisplayName: 'Priya',
  seq: 1,
  content: 'the seq ordering on resync looks wrong',
  createdAt: 1700000000000,
  editedAt: null,
);

final _router = GoRouter(routes: const []);

typedef _Surface = Widget Function();

final _surfaces = <String, ({_Surface build, bool hasAvatar})>{
  'search hit': (
    build: () => SearchResultRow(
      message: _message,
      knownUsernames: const {},
      customEmoji: const {},
      onSelect: (_) {},
    ),
    hasAvatar: false,
  ),
  'thread parent card': (
    build: () => const ThreadParentCard(
      parent: api.ThreadParent(
        parentChannelId: 'c1',
        parentMessageId: 'm1',
        parentContent: 'the seq ordering on resync looks wrong',
        parentAuthorId: 'author-1',
        parentAuthorDisplayName: 'Priya',
      ),
      threadChannelId: 't1',
    ),
    hasAvatar: true,
  ),
  'pinned row': (
    build: () => PinnedMessageRow(
      channelId: 'c1',
      pin: const api.PinnedMessage(
        message: _message,
        pinnedAt: 0,
        pinnedBy: 'author-1',
      ),
      router: _router,
      currentChannelId: 'c1',
    ),
    hasAvatar: true,
  ),
  'saved row': (
    build: () => SavedMessageRow(
      saved: const api.SavedMessage(message: _message, savedAt: 0),
      router: _router,
      currentChannelId: 'c1',
    ),
    hasAvatar: true,
  ),
  'thread row': (
    build: () => ThreadRow(
      router: _router,
      thread: const api.ThreadListItem(
        id: 't1',
        parentMessageId: 'm1',
        parentContent: 'the seq ordering on resync looks wrong',
        parentAuthorId: 'author-1',
        parentAuthorDisplayName: 'Priya',
        createdAt: 0,
        replyCount: 2,
        lastReplyAt: 0,
        unreadCount: 0,
      ),
    ),
    hasAvatar: true,
  ),
};

Future<({double height, double? avatar})> _measure(
  WidgetTester tester,
  AppDensity density,
  Widget Function() build,
) async {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  await container
      .read(messageDensityControllerProvider.notifier)
      .select(density);
  final key = GlobalKey();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: KeyedSubtree(key: key, child: build()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final avatars = find.byType(AppAvatar);
  final measured = (
    height: tester.getSize(find.byKey(key)).height,
    avatar: avatars.evaluate().isEmpty
        ? null
        : tester.getSize(avatars.first).height,
  );
  // Unmount inside the test so autodispose providers flush their timers.
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  return measured;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in _surfaces.entries) {
    testWidgets('${entry.key} is shorter at compact than at default', (
      tester,
    ) async {
      final compact = await _measure(
        tester,
        AppDensity.compact,
        entry.value.build,
      );
      final normal = await _measure(
        tester,
        AppDensity.normal,
        entry.value.build,
      );
      expect(compact.height, lessThan(normal.height));
    });

    testWidgets('${entry.key} is taller at spacious than at default', (
      tester,
    ) async {
      final normal = await _measure(
        tester,
        AppDensity.normal,
        entry.value.build,
      );
      final spacious = await _measure(
        tester,
        AppDensity.spacious,
        entry.value.build,
      );
      expect(spacious.height, greaterThan(normal.height));
    });

    if (entry.value.hasAvatar) {
      testWidgets('${entry.key} avatar steps down at compact', (tester) async {
        final compact = await _measure(
          tester,
          AppDensity.compact,
          entry.value.build,
        );
        final normal = await _measure(
          tester,
          AppDensity.normal,
          entry.value.build,
        );
        expect(compact.avatar, lessThan(normal.avatar!));
      });
    }
  }

  testWidgets('avatar sizes match the density tokens', (tester) async {
    final card = _surfaces['thread parent card']!.build;
    final row = _surfaces['pinned row']!.build;
    expect(
      (await _measure(tester, AppDensity.compact, card)).avatar,
      AppDensity.compact.avatarSize,
    );
    expect(
      (await _measure(tester, AppDensity.normal, card)).avatar,
      AppDensity.normal.avatarSize,
    );
    expect(
      (await _measure(tester, AppDensity.compact, row)).avatar,
      AppAvatarSize.s24,
    );
    expect(
      (await _measure(tester, AppDensity.normal, row)).avatar,
      AppAvatarSize.s28,
    );
  });
}
