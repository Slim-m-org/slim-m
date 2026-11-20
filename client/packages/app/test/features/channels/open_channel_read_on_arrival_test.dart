// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live message in the open channel, read on sight, is stored already read:
/// the rail's channel list does not rebuild for it, where it used to rebuild
/// twice (unread on, then off as the read marker followed). Read away from the
/// newest message, or in a window nobody is looking at, it still counts as unread.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/arrival_readers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_refresher.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/sync/providers/sync_event_applier.dart';
import 'package:slimm_data/data.dart';

import '../../support/window_lifecycle.dart';
import '../settings/home_shell_harness.dart';

api.Message _message(int seq) => api.Message(
  id: 'c1-m$seq',
  channelId: 'c1',
  authorId: 'u',
  authorDisplayName: 'U',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
  editedAt: null,
);

/// The live path a socket frame takes, without the socket.
final _applier = Provider<SyncEventApplier>(
  (ref) => SyncEventApplier(
    ref,
    (_) => true,
    ChannelRefresher(),
    () async {},
    () async {},
  ),
);

class _World {
  _World(this.tester, this.container, this.db, this.marked);

  final WidgetTester tester;
  final ProviderContainer container;
  final SlimmDatabase db;

  /// The seqs `markRead` told the server, in order.
  final List<int> marked;

  late final store = MessageStore(db);

  /// Drift answers in real time and riverpod resolves on the fake clock, so each needs its turn.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Future<void> deliver(int seq) async {
    final applier = container.read(_applier);
    final client = container.read(apiProvider);
    await tester.runAsync(
      () => applier.apply(0, client, store, api.MessageCreated(_message(seq))),
    );
    await settle();
  }

  Future<Channel> c1() async => (await tester.runAsync(
    () => store.watchRailChannels().first,
  ))!.firstWhere((c) => c.id == 'c1');
}

/// A screen that would have read the message but closed while it was being stored.
class _GoneReader implements ArrivalReader {
  @override
  bool readsOnArrival(String channelId) => channelId == 'c1';

  @override
  bool readOnArrival(String channelId, int seq) => false;
}

Future<_World> _open(
  WidgetTester tester, {
  int messages = 1,
  List<Override> overrides = const [],
  String location = '/channels/c1',
}) async {
  final marked = <int>[];
  final quiet = quietClient();
  final client = MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'PUT' && path.endsWith('/channels/c1/read')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      marked.add((body['seq']! as num).toInt());
    }
    return http.Response.fromStream(await quiet.send(request));
  });
  final s = setup(
    httpClient: client,
    signedIn: true,
    extraOverrides: overrides,
  );
  final world = _World(tester, s.container, s.db, marked);
  await tester.runAsync(() async {
    await world.store.upsertChannels(const [
      api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
      api.Channel(id: 'c2', name: 'two', kind: 'text', createdAt: 1),
    ]);
    await world.store.applyMessages([
      for (var seq = 1; seq <= messages; seq++) _message(seq),
    ]);
  });
  await pumpAtWidth(tester, s.container, 1400, location: location);
  await world.settle();
  return world;
}

void main() {
  late List<String> rebuilt;

  setUp(() => rebuilt = []);
  tearDown(() => debugOnRebuildDirtyWidget = null);

  testWidgets('a message read as it arrives in the open channel rebuilds '
      'no rail list and still reaches the server', (tester) async {
    final w = await _open(tester);
    expect((await w.c1()).lastReadSeq, 1, reason: 'the open channel was read');

    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is StreamBuilder<List<Channel>>) {
        rebuilt.add('channel list');
      }
    };
    await w.deliver(2);

    expect((await w.c1()).lastReadSeq, 2, reason: 'the new message was read');
    expect(rebuilt, isEmpty);
    expect(w.marked.last, 2, reason: 'the server is told it was read');

    debugOnRebuildDirtyWidget = null;
    await teardown(tester, w.container, w.db);
  });

  testWidgets('a screen that closed while the message was stored still gets '
      'the server told', (tester) async {
    final w = await _open(tester, location: '/channels/c2');
    w.container.read(arrivalReadersProvider).add(_GoneReader());

    await w.deliver(2);

    expect((await w.c1()).lastReadSeq, 2);
    expect(w.marked, contains(2), reason: 'the applier sent it itself');
    await teardown(tester, w.container, w.db);
  });

  testWidgets('a message arriving while scrolled into history stays unread', (
    tester,
  ) async {
    final w = await _open(tester, messages: 60);
    expect((await w.c1()).lastReadSeq, 60);
    await tester.dragFrom(const Offset(700, 300), const Offset(0, 500));
    await w.settle();

    await w.deliver(61);

    final c1 = await w.c1();
    expect(c1.lastReadSeq, 60, reason: 'the reader is not at the newest');
    expect(c1.standingSeq, 61);
    await teardown(tester, w.container, w.db);
  });

  testWidgets('a message arriving in an unfocused window stays unread', (
    tester,
  ) async {
    final window = windowIn(AppLifecycleState.resumed);
    final w = await _open(tester, overrides: [windowLifecycle(window)]);
    expect((await w.c1()).lastReadSeq, 1);
    window.setFocused(false);
    await w.settle();

    await w.deliver(2);

    expect((await w.c1()).lastReadSeq, 1, reason: 'nobody is looking');
    window.setFocused(true);
    await w.settle();
    expect((await w.c1()).lastReadSeq, 2, reason: 'read once it is seen');
    await teardown(tester, w.container, w.db);
  });
}
