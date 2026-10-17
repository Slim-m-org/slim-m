// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel marked unread by hand, then opened, must clear the mark.
///
/// The mark-unread route deliberately does not rewind the seq (see
/// `mark_unread.rs`), so a channel that is already fully caught up when it is
/// marked unread has nothing new to read: `newestSeq == lastReadSeq`.
/// `ReadMarker.advance` used to bail out whenever the seq was not advancing,
/// before it ever reached the write that clears `manuallyUnread` - so opening
/// a channel marked unread this way never cleared the flag, and the rail dot
/// never went out.
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
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _seedCount = 3;

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
/// settling never returns. See `channel_screen_read_marker_scroll_test.dart`.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Harness {
  _Harness({
    required this.markReadSeqs,
    required this.db,
    required this.seeded,
  });

  final List<int> markReadSeqs;
  final SlimmDatabase db;

  /// The row exactly as seeded, read before the widget ever mounts: proof
  /// the reproduction is real, since reading it back after mounting would
  /// only show the fix's own result.
  final Channel seeded;
}

Future<_Harness> _mount(WidgetTester tester) async {
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
  // Fully read, then marked unread without moving the marker, as `PUT .../unread` does.
  await store.setReadMarker('c1', _seedCount, manuallyUnread: true);
  final seeded = await _channel(db);

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
                jsonEncode({
                  'last_read_seq': seq,
                  'unread': 0,
                  'manually_unread': false,
                }),
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
            // Members, pins, and the extras-hydration fetch answer empty; none of them are what this test is about.
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

  return _Harness(markReadSeqs: markReadSeqs, db: db, seeded: seeded);
}

Future<Channel> _channel(SlimmDatabase db) =>
    (db.select(db.channels)..where((c) => c.id.equals('c1'))).getSingle();

/// Same formula `rail_channel.dart`'s `railChannelKey` draws the dot from -
/// this asserts the indicator's actual, derived state rather than a single
/// field or that some provider ran.
bool _showsUnread(Channel channel) =>
    channel.cursor > channel.lastReadSeq || (channel.manuallyUnread ?? false);

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
  testWidgets('opening a channel marked unread by hand clears the mark even though '
      'there is nothing new to read', (tester) async {
    final h = await _mount(tester);

    expect(
      _showsUnread(h.seeded),
      isTrue,
      reason:
          'seeding must reproduce the reported state before asserting the fix',
    );

    expect(
      h.markReadSeqs,
      contains(_seedCount),
      reason:
          'opening the channel must tell the server, even with the seq unchanged',
    );

    final after = await _channel(h.db);
    expect(
      after.manuallyUnread,
      isFalse,
      reason:
          'sitting in the channel with it fully in view must clear the hand mark',
    );
    expect(
      _showsUnread(after),
      isFalse,
      reason: 'the rail dot this channel would draw must actually go out',
    );

    await _unmount(tester);
  });
}
