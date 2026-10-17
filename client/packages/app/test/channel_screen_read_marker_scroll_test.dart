// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The read marker used to follow the newest delivered message regardless of
/// where the reader had scrolled: `_markReadUpToLatest` ran unconditionally
/// from the transcript's `StreamBuilder`, so scrolling back into history to
/// re-read something silently marked everything below it read too.
///
/// The fix has to get two traps right in opposite directions. Gating on the
/// scroll position must still treat a first paint, before the scrollable has
/// laid out, as "at the latest" (the list is bottom-anchored, so it always
/// starts there) or a channel never marks read at all. And a rebuild is not
/// enough to notice the reader scrolling back: scrolling never rebuilds the
/// transcript's `StreamBuilder`, so returning to the latest message needs its
/// own trigger.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Enough rows to overflow a 500x800 viewport well past the composer, so
/// there is somewhere real to scroll away to.
const _seedCount = 80;

api.Message _message(String id, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 60000,
  editedAt: null,
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

/// A bounded pump count, not `pumpAndSettle`: `AppButton`'s hover/focus
/// machinery keeps a frame scheduled forever in this environment, so
/// settling never returns. 30 x 20ms comfortably outlasts the affordance's
/// `AppMotion.slow` scroll animation and its own fade transition.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// What one test needs to observe: the read-state writes that left for the
/// server, and the local store both were driven through.
class _Harness {
  _Harness({required this.markReadSeqs, required this.db, required this.store});

  final List<int> markReadSeqs;
  final SlimmDatabase db;
  final MessageStore store;
}

Future<_Harness> _mount(
  WidgetTester tester, {
  Future<void> Function(MessageStore store)? beforeOpen,
}) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final markReadSeqs = <int>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);

  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages([
    for (var seq = 1; seq <= _seedCount; seq++) _message('m$seq', seq),
  ]);
  await beforeOpen?.call(store);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' &&
                request.url.path == '/channels/c1/read') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final seq = body['seq'] as int;
              markReadSeqs.add(seq);
              return http.Response(
                jsonEncode({'last_read_seq': seq, 'unread': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                jsonEncode(_meJson()),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            // Members, pins, and the extras-hydration fetch answer empty; none of them are what these tests are about.
            return _emptyJsonList();
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ),
  );
  await _flush(tester);

  return _Harness(markReadSeqs: markReadSeqs, db: db, store: store);
}

/// The transcript's own [ScrollController], the same instance `ChannelScreen`
/// drives internally: mutating it here is exactly what a real user's drag
/// would do to it, not a parallel channel to the state under test.
ScrollController _transcriptScroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

Future<int> _lastReadSeq(SlimmDatabase db) async {
  final row = await (db.select(
    db.channels,
  )..where((c) => c.id.equals('c1'))).getSingle();
  return row.lastReadSeq;
}

/// Unmounting deliberately, with a few more pumps, rather than letting
/// flutter_test's own teardown do it; see `channel_screen_test.dart` for why
/// drift's deferred stream cleanup needs this.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets(
    'a channel whose newest message was deleted before it was read still '
    'clears its unread mark when opened',
    (tester) async {
      final h = await _mount(
        tester,
        beforeOpen: (store) async {
          await store.applyMessage(_message('gone', _seedCount + 1));
          await store.discard('gone');
        },
      );

      expect(
        h.markReadSeqs,
        contains(_seedCount + 1),
        reason:
            'the deleted message advanced the channel past every visible one',
      );
      expect(await _lastReadSeq(h.db), _seedCount + 1);

      await _unmount(tester);
    },
  );

  testWidgets(
    'opening a channel before the scroll view has laid out still marks it '
    'read, the same as before this change',
    (tester) async {
      final h = await _mount(tester);

      expect(
        h.markReadSeqs,
        contains(_seedCount),
        reason:
            'a first paint has nothing to have scrolled away from and must '
            'be treated as already at the latest message',
      );
      expect(await _lastReadSeq(h.db), _seedCount);

      await _unmount(tester);
    },
  );

  testWidgets(
    'scrolled away from the newest message, a new arrival is not marked read',
    (tester) async {
      final h = await _mount(tester);

      final scroll = _transcriptScroll(tester);
      expect(
        scroll.position.maxScrollExtent,
        greaterThan(0),
        reason:
            'the seeded history must overflow the viewport, or there is '
            'nowhere to scroll away to',
      );
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await _flush(tester);

      h.markReadSeqs.clear();
      await h.store.applyMessages([
        _message('m${_seedCount + 1}', _seedCount + 1),
      ]);
      await _flush(tester);

      expect(
        h.markReadSeqs,
        isNot(contains(_seedCount + 1)),
        reason:
            'the reader is looking at history, not the new message, so the '
            'server must not be told it was read',
      );
      expect(await _lastReadSeq(h.db), lessThan(_seedCount + 1));

      await _unmount(tester);
    },
  );

  testWidgets(
    'scrolling back to the newest message marks a missed arrival read',
    (tester) async {
      final h = await _mount(tester);

      final scroll = _transcriptScroll(tester);
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await _flush(tester);

      h.markReadSeqs.clear();
      await h.store.applyMessages([
        _message('m${_seedCount + 1}', _seedCount + 1),
      ]);
      await _flush(tester);
      // Not this test's own claim, just the starting point it continues from.
      expect(h.markReadSeqs, isNot(contains(_seedCount + 1)));

      scroll.jumpTo(scroll.position.minScrollExtent);
      await _flush(tester);

      expect(
        h.markReadSeqs,
        contains(_seedCount + 1),
        reason:
            'returning to the newest message must re-run the read marker; '
            'a rebuild never happens on its own from scrolling alone',
      );
      expect(await _lastReadSeq(h.db), _seedCount + 1);

      await _unmount(tester);
    },
  );

  testWidgets('the jump-to-latest affordance shows only once scrolled away and '
      'heading back, and returns to the latest message when tapped', (
    tester,
  ) async {
    await _mount(tester);

    // Icon-only now (jump_to_latest_button.dart), so found by key not text.
    const jumpButton = Key('jump-to-latest-tap-target');
    expect(find.byKey(jumpButton), findsNothing);

    final scroll = _transcriptScroll(tester);
    // Away, then a step back toward latest: the arrow only reveals itself on that second, "heading back" sample.
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await _flush(tester);
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await _flush(tester);

    expect(find.byKey(jumpButton), findsOneWidget);

    await tester.tap(find.byKey(jumpButton));
    await _flush(tester);

    expect(
      scroll.position.pixels,
      closeTo(scroll.position.minScrollExtent, 1),
      reason:
          'tapping it must be wired to the same scroll-to-latest '
          'animation the composer already uses after a send',
    );
    expect(find.byKey(jumpButton), findsNothing);

    await _unmount(tester);
  });
}
