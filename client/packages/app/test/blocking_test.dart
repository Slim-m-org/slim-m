// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Blocking, from the transcript's side.
///
/// The bug this pins: the block list lived in an `autoDispose` provider read
/// only by the settings pane that lists it, so outside that pane nothing was
/// filtered anywhere, while the app told the user "their messages are hidden
/// for you". Every assertion here is against the running screen rather than
/// against a filter helper, because the defect was never in a filter - there
/// was no filter.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_sync.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message({
  required String id,
  required String authorId,
  required int seq,
  required String content,
}) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorId,
  seq: seq,
  content: content,
  createdAt: seq * 1000,
  editedAt: null,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container wired at a channel holding one message from each of two authors,
/// with [blocked] as the server's answer to `GET /blocks`.
Future<({ProviderContainer container, List<int> markReadSeqs})> _wire(
  WidgetTester tester, {
  required List<String> blocked,
  bool blocksFail = false,
}) async {
  // Compact, so the header and everything it pulls in never builds.
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
    _message(id: 'm1', authorId: 'friend', seq: 1, content: 'from a friend'),
    _message(id: 'm2', authorId: 'pest', seq: 2, content: 'from a pest'),
  ]);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        if (request.url.path == '/blocks') {
          if (blocksFail) return http.Response('nope', 500);
          // Keyed on the token, so a second account's list is its own.
          final own = request.headers['authorization'] == 'Bearer access';
          return _json(own ? blocked : const <String>[]);
        }
        if (request.method == 'PUT' &&
            request.url.path == '/channels/c1/read') {
          final seq =
              (jsonDecode(request.body) as Map<String, dynamic>)['seq'] as int;
          markReadSeqs.add(seq);
          return _json({'last_read_seq': seq, 'unread': 0});
        }
        if (request.url.path == '/me') {
          return _json({
            'id': 'me',
            'username': 'me',
            'display_name': 'Me',
            'created_at': 0,
            'permissions': 0,
          });
        }
        return _json(const <Object>[]);
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
  // Bounded, not pumpAndSettle: AppIconButton never stops asking for frames.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return (container: container, markReadSeqs: markReadSeqs);
}

/// Unmounts deliberately, for the reason `channel_screen_test.dart` records:
/// drift defers a cancelled query stream's cleanup by one turn on a
/// zero-duration timer, and flutter_test's own teardown checks for pending
/// timers before that turn arrives.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('a blocked author is absent from the transcript', (tester) async {
    await _wire(tester, blocked: ['pest']);

    expect(find.text('from a friend'), findsOneWidget);
    expect(
      find.text('from a pest'),
      findsNothing,
      reason: 'the whole point of blocking, and it did nothing before this',
    );
    await _unmount(tester);
  });

  testWidgets('nothing is filtered when nobody is blocked', (tester) async {
    await _wire(tester, blocked: const []);

    expect(find.text('from a friend'), findsOneWidget);
    expect(find.text('from a pest'), findsOneWidget);
    await _unmount(tester);
  });

  /// The reason the filter is at read time rather than on the way in: the local
  /// store keeps everything, so unblocking restores the transcript without a
  /// refetch. Filtering `/sync` instead would need a full channel reset.
  testWidgets('unblocking restores the messages with no refetch', (
    tester,
  ) async {
    final wired = await _wire(tester, blocked: ['pest']);
    expect(find.text('from a pest'), findsNothing);

    await wired.container.read(blocksProvider.notifier).unblock('pest');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      find.text('from a pest'),
      findsOneWidget,
      reason: 'the row was never removed from the local database',
    );
    await _unmount(tester);
  });

  /// A blocked author's message is hidden, not unreceived. If read state only
  /// counted what was shown, a channel whose newest message came from a blocked
  /// author would stay lit as unread forever with no way to clear it.
  testWidgets('a blocked author still advances the read marker', (
    tester,
  ) async {
    final wired = await _wire(tester, blocked: ['pest']);

    expect(
      wired.markReadSeqs,
      contains(2),
      reason: 'seq 2 is the blocked author\'s message, and it was received',
    );
    await _unmount(tester);
  });

  /// An unreachable block list must not hold the transcript empty. It is a
  /// failure to filter, which the settings pane reports; a blank channel would
  /// be a failure to work.
  testWidgets('a block list that will not load does not blank the channel', (
    tester,
  ) async {
    final wired = await _wire(tester, blocked: const [], blocksFail: true);

    expect(find.text('from a friend'), findsOneWidget);
    expect(wired.container.read(blocksProvider).error, isNotNull);
    expect(
      wired.container.read(blocksProvider).settled,
      isTrue,
      reason: 'a failure settles too, so the settings pane can say so',
    );
    expect(
      find.text('from a pest'),
      findsOneWidget,
      reason:
          'and nothing is filtered, which is the right one of the two: a '
          'transcript held empty behind an unreachable block list is worse '
          'than an unfiltered one',
    );
    await _unmount(tester);
  });

  /// A token rotation is not a new account. The session stream fires on every
  /// automatic access-token refresh, and refetching on those made routine
  /// rotation a race against an in-flight block: a `GET /blocks` sent before
  /// the block landed and answering after it would silently unblock somebody
  /// the app had just confirmed as blocked.
  testWidgets('a token rotation does not refetch or clobber the block set', (
    tester,
  ) async {
    final wired = await _wire(tester, blocked: const []);
    final controller = wired.container.read(blocksProvider.notifier);
    final session = wired.container.read(sessionProvider);

    await controller.block('pest');
    expect(wired.container.read(blocksProvider).ids, contains('pest'));

    // Same account, new access token: exactly what a refresh publishes.
    session.set(
      const api.TokenPair(
        userId: 'me',
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        accessExpiresAt: 0,
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      wired.container.read(blocksProvider).ids,
      contains('pest'),
      reason: 'the rotation must not have refetched over the block',
    );
    expect(find.text('from a pest'), findsNothing);
    await _unmount(tester);
  });

  /// A different account signing in on the same device does refetch, and starts
  /// from nothing rather than inheriting the previous account's set.
  testWidgets('a different account signing in replaces the block set', (
    tester,
  ) async {
    final wired = await _wire(tester, blocked: ['pest']);
    expect(wired.container.read(blocksProvider).ids, contains('pest'));

    wired.container
        .read(sessionProvider)
        .set(
          const api.TokenPair(
            userId: 'someone-else',
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            accessExpiresAt: 0,
          ),
        );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      wired.container.read(blocksProvider).ids,
      isEmpty,
      reason: 'the new account gets its own list, not the previous one\'s',
    );
    expect(
      find.text('from a pest'),
      findsOneWidget,
      reason: 'and nothing is hidden from them on the old account\'s behalf',
    );
    await _unmount(tester);
  });

  /// The local database is one file for the whole app, so a block set that
  /// outlived a sign-out would silently hide messages from whoever signed in
  /// next on the device.
  testWidgets('signing out empties the block set', (tester) async {
    final wired = await _wire(tester, blocked: ['pest']);
    expect(wired.container.read(blocksProvider).ids, contains('pest'));

    wired.container.read(sessionProvider).clear();
    await tester.pump();

    expect(wired.container.read(blocksProvider).ids, isEmpty);
    expect(wired.container.read(blocksProvider).settled, isFalse);
    await _unmount(tester);
  });
}
