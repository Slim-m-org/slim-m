// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for the stacked-header bug: `ThreadScreen` wraps
/// `ChannelScreen` in its own `AppBar`, and `ChannelScreen` used to build a
/// second `ChannelHeader` underneath it at any width that shows both panes -
/// two bars where there should be one. Covers both layouts, since the same
/// wrapper drives compact and expanded and only expanded was reported.
///
/// `ThreadParentCard`'s own rendering is `thread_parent_card_test.dart`,
/// split out for the file budget.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

/// `GET /channels/c1/thread-parent`'s answer: all-null (not a thread, or
/// unresolved) unless a test names a real parent.
http.Response _threadParentJson({
  String? parentChannelId,
  String? parentChannelName,
  String? parentMessageId,
  String? parentContent,
  bool parentDeleted = false,
  String? parentAuthorId,
  String? parentAuthorDisplayName,
}) => http.Response(
  jsonEncode({
    'parent_channel_id': parentChannelId,
    'parent_channel_name': parentChannelName,
    'parent_message_id': parentMessageId,
    'parent_content': parentContent,
    'parent_deleted': parentDeleted,
    'parent_author_id': parentAuthorId,
    'parent_author_display_name': parentAuthorDisplayName,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

/// Pumps a [ThreadScreen] for channel `c1`, a thread (`parentMessageId` set),
/// reached by pushing it over a marker screen so the back button has
/// somewhere real to return to - the same shape a "Reply in thread" push
/// produces in the app. Returns the container so a test can read provider
/// state the widget tree itself does not surface, e.g. that a control kept
/// in the header acted on the thread's own channel id and nothing else.
/// [seedChannelRow] defaults to true, the shape every existing test in this
/// file relies on. Pass false to reproduce a deep link, a reload while
/// inside a thread, or `scripts/lib/e2e_threads.py` navigating straight to
/// `#/thread/{id}` - none of which have ever fetched `GET /channels` or
/// `GET /dms`, so the local store carries no row for the thread at all
/// (docs/decisions/0005-threads.md, threads are excluded from both by
/// design) and `channel?.parentMessageId` alone cannot tell `ChannelScreen`
/// it is inside a thread.
Future<ProviderContainer> _pumpThread(
  WidgetTester tester,
  Size size, {
  bool seedChannelRow = true,
  http.Response? threadParentResponse,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  if (seedChannelRow) {
    await store.upsertChannels([
      const api.Channel(
        id: 'c1',
        name: '',
        kind: 'text',
        createdAt: 0,
        parentMessageId: 'parent-1',
      ),
    ]);
  }

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        if (request.method == 'GET' && request.url.path == '/me') {
          return http.Response(
            jsonEncode(_meJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/channels/c1/thread-parent') {
          return threadParentResponse ?? _threadParentJson();
        }
        return _emptyJsonList();
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ThreadScreen(channelId: 'c1'),
                  ),
                ),
                child: const Text('open thread'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open thread'));
  // A bounded pump count, not pumpAndSettle: AppIconButton's ripple keeps requesting a frame.
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return container;
}

/// Unmounts before the framework's own teardown does: `ChannelScreen`'s
/// `StreamBuilder`s cancel their drift query streams on dispose, and drift
/// defers that cleanup by one event loop turn on a zero-duration `Timer`,
/// which the "no pending timers" check would otherwise catch as a false
/// failure unrelated to what the test covers.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  for (final entry in {
    'compact': const Size(500, 800),
    'expanded': const Size(1400, 900),
  }.entries) {
    testWidgets('a thread shows exactly one header, at ${entry.key} width', (
      tester,
    ) async {
      await _pumpThread(tester, entry.value);

      expect(
        find.byType(ChannelHeader),
        findsNothing,
        reason:
            'ChannelScreen must not build its own header for a thread '
            "channel; ThreadScreen's AppBar is the only one",
      );
      expect(
        find.text('Thread'),
        findsOneWidget,
        reason: 'exactly one bar, carrying exactly one title',
      );

      await _settle(tester);
    });

    testWidgets(
      'a thread header has a working back affordance, at ${entry.key} width',
      (tester) async {
        await _pumpThread(tester, entry.value);

        final back = find.byTooltip('Back to the conversation');
        expect(back, findsOneWidget);
        await tester.tap(back);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          find.text('open thread'),
          findsOneWidget,
          reason:
              'tapping back must return to the screen the thread opened '
              'from',
        );

        await _settle(tester);
      },
    );

    testWidgets(
      'a thread header carries only the back affordance, the title, and '
      'search, at ${entry.key} width',
      (tester) async {
        await _pumpThread(tester, entry.value);

        expect(
          find.bySemanticsLabel('Pinned messages'),
          findsNothing,
          reason:
              'a thread has no browsing surface for a pinned set to be '
              'rediscovered later; pin is not inherited from the channel '
              'header',
        );
        expect(
          find.bySemanticsLabel('Open canvas'),
          findsNothing,
          reason:
              'a canvas button inside a thread was flagged as an unwanted '
              'surface by the 2026-08-02 security review',
        );
        expect(
          find.bySemanticsLabel('Toggle member list'),
          findsNothing,
          reason:
              'this toggle drives a global memberPaneVisibleProvider that '
              "HomeShell reads for the parent channel underneath, not the "
              'thread - the reported bug of a thread control acting on the '
              'channel behind it',
        );
        expect(
          find.bySemanticsLabel('Toggle channel list'),
          findsNothing,
          reason:
              'the same global-state shape as the member toggle, over '
              'channelRailExpandedProvider',
        );
        expect(
          find.bySemanticsLabel('Call'),
          findsNothing,
          reason: 'a thread is not a DM call surface',
        );
        expect(
          find.bySemanticsLabel('Search messages'),
          findsOneWidget,
          reason: "search is the one action a thread's header keeps",
        );

        await _settle(tester);
      },
    );

    testWidgets(
      'a thread header search acts on the thread, never the parent channel, '
      'at ${entry.key} width',
      (tester) async {
        final container = await _pumpThread(tester, entry.value);

        await tester.tap(find.bySemanticsLabel('Search messages'));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(
          container.read(channelSearchProvider('c1')).open,
          isTrue,
          reason: "the thread's own search state must open",
        );
        expect(
          container.read(channelSearchProvider('parent-channel')).open,
          isFalse,
          reason:
              'channelSearchProvider is keyed per channel id, so opening '
              "search in the thread must not touch the parent channel's "
              'copy of the same provider',
        );

        await _settle(tester);
      },
    );
  }

  testWidgets(
    'the thread app bar carries a bottom border, as the phone one does',
    (tester) async {
      await _pumpThread(tester, const Size(900, 700));

      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(
        bar.shape,
        isA<Border>(),
        reason:
            'this bar shares surfaceBase with the transcript at zero elevation, '
            'so without a border there is no boundary between the two',
      );

      await _settle(tester);
    },
  );

  /// Guards only the fix's own load-bearing line, not the browser bug it
  /// fixes: flutter_test's own SemanticsNode tree already gave "Thread" a
  /// distinct label with or without this wrapper (checked by hand, see
  /// thread_screen.dart's own doc comment), so it cannot reproduce what only
  /// the web engine's flt-semantics DOM projection did - collapse the title
  /// into the AppBar's own unlabelled node. That is proven by a real
  /// headless-browser run instead (`scripts/e2e.sh`, `messaging: a thread
  /// stays off the ordinary channel list`), not by this test.
  testWidgets(
    'the thread title is wrapped in a semantics boundary of its own',
    (tester) async {
      await _pumpThread(tester, const Size(900, 700));

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      final title = appBar.title;
      expect(title, isA<Semantics>());
      expect(
        (title! as Semantics).container,
        isTrue,
        reason:
            'container: true is what forces a semantics boundary for the '
            'title rather than letting it merge into an ancestor node',
      );

      await _settle(tester);
    },
  );

  /// Compact width never builds ChannelHeader regardless of parentMessageId
  /// (layout.showsBothPanes is false there), so only expanded width exercises
  /// the bug this guards: ChannelScreen used to decide "am I a thread" from
  /// the store row alone, which a deep link never seeds.
  testWidgets(
    'a thread reached with no local channel row still shows exactly one '
    'header, never the parent channel chrome',
    (tester) async {
      await _pumpThread(tester, const Size(1400, 900), seedChannelRow: false);

      expect(
        find.byType(ChannelHeader),
        findsNothing,
        reason:
            'with no store row, channel?.parentMessageId reads null; '
            "ChannelScreen must still know it is a thread from "
            "ThreadScreen's own isThread flag",
      );
      expect(find.text('Thread'), findsOneWidget);
      expect(find.bySemanticsLabel('Pinned messages'), findsNothing);
      expect(find.bySemanticsLabel('Open canvas'), findsNothing);
      expect(find.bySemanticsLabel('Toggle member list'), findsNothing);
      expect(find.bySemanticsLabel('Toggle channel list'), findsNothing);

      await _settle(tester);
    },
  );

  /// docs/reports/screen-review/shell.md's biggest shell finding: a thread
  /// panel gave no orientation once you were inside it.
  testWidgets('the thread title names the parent channel once it resolves', (
    tester,
  ) async {
    await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _threadParentJson(
        parentChannelId: 'parent-channel',
        parentChannelName: 'general',
        parentMessageId: 'parent-1',
      ),
    );

    expect(find.text('Thread in #general'), findsOneWidget);
    expect(find.text('Thread'), findsNothing);

    await _settle(tester);
  });

  /// The same shell.md report's other thread finding: a cold-opened thread
  /// never got a local `channels` row, so `setReadMarker`'s plain `UPDATE`
  /// silently no-op'd forever. Once `threadParentProvider` resolves, a real
  /// row - carrying the real `parentMessageId`, not a placeholder - must
  /// exist for the read marker to write into.
  testWidgets(
    'a cold-opened thread gets a real local row once its parent resolves',
    (tester) async {
      final container = await _pumpThread(
        tester,
        const Size(1400, 900),
        seedChannelRow: false,
        threadParentResponse: _threadParentJson(
          parentChannelId: 'parent-channel',
          parentChannelName: 'general',
          parentMessageId: 'parent-1',
        ),
      );
      final store = await container.read(storeProvider.future);

      /// The upsert this proves is `unawaited` from `initState`, so it can
      /// still be mid-write once the tap that started it has settled;
      /// pumping between checks gives its own await chain room to finish.
      /// `channelRow`, not `allChannels`: a thread is deliberately excluded
      /// from the latter, mirroring the server's own `list_channels`.
      Channel? row;
      for (var i = 0; i < 10 && row == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        row = await store.channelRow('c1');
      }
      expect(
        row,
        isNotNull,
        reason: 'the read marker has nothing to write into without a row',
      );
      expect(
        row!.parentMessageId,
        'parent-1',
        reason:
            'must be the real id thread-parent resolved, not a placeholder '
            "null - a null parentMessageId would make replaceChannels's own "
            'pruning rule mistake this thread for one that dropped off the '
            "server's list",
      );

      await _settle(tester);
    },
  );
}
