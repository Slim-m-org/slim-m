// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real [SyncController] and store against [SyncModelServer], with the wire
/// and each catch-up answer held where a test can lose, repeat or delay them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'sync_model_server.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class SyncModelWorld {
  SyncModelWorld({SyncModelServer? server, this.makeStore})
    : server = server ?? SyncModelServer();

  final SyncModelServer server;
  final MessageStore Function(SlimmDatabase db)? makeStore;

  /// Frames the server sent that the client has not been handed yet.
  final wire = <api.ServerEvent>[];
  final _heldAnswers = <Completer<void>>[];

  /// Whether the next `/sync` answers wait for [releaseAnswer].
  bool holdAnswers = false;
  int _inFlight = 0;

  /// How many times the newest page was fetched, which is what a reset costs.
  int newestPageReads = 0;

  late final SlimmDatabase db;
  late final MessageStore store;
  late final ProviderContainer container;
  late final SyncController controller;

  Future<void> open() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = makeStore?.call(db) ?? MessageStore(db);
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        syncChunkRetryDelaysProvider.overrideWithValue(const []),
        apiProvider.overrideWith((ref) {
          final client = testApi(
            _answer,
            session: api.SessionStore(tokens: _tokens),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    controller = container.read(syncControllerProvider.notifier);
    await store.upsertChannels([
      api.Channel(
        id: server.channelId,
        name: 'general',
        kind: 'text',
        createdAt: 0,
      ),
    ]);
  }

  Future<void> close() async {
    container.dispose();
    await db.close();
  }

  Future<http.Response> _answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/sync') {
      _inFlight++;
      // Read now, delivered later: an answer in flight is older than what lands meanwhile.
      final body = server.sync(
        jsonDecode(request.body) as Map<String, dynamic>,
      );
      if (holdAnswers) {
        final gate = Completer<void>();
        _heldAnswers.add(gate);
        await gate.future;
      }
      _inFlight--;
      return jsonHttpResponse(body);
    }
    if (path == '/channels/${server.channelId}/messages') {
      newestPageReads++;
      return jsonHttpResponse(server.newest());
    }
    return jsonHttpResponse(const <String, dynamic>{});
  }

  void releaseAnswer() {
    if (_heldAnswers.isNotEmpty) _heldAnswers.removeAt(0).complete();
  }

  /// Hands the client the frame at [at] on the wire, leaving it there when [repeat].
  Future<void> deliver({int at = 0, bool repeat = false}) async {
    final frame = repeat ? wire[at] : wire.removeAt(at);
    await controller.applyServerEventForTest(frame);
  }

  /// A catch-up whose answer is read now and lands when [releaseAnswer] is called.
  Future<void> startHeldCatchUp() async {
    holdAnswers = true;
    unawaited(controller.reconcile());
    await pumpEventQueue();
  }

  /// Everything in flight lands or is lost, then catch-up runs until it is idle.
  Future<void> settle() async {
    holdAnswers = false;
    wire.clear();
    for (var round = 0; round < 50; round++) {
      while (_heldAnswers.isNotEmpty) {
        releaseAnswer();
      }
      await pumpEventQueue(times: 10);
      if (_inFlight == 0 && round >= 2) break;
    }
    await controller.reconcile();
    await controller.reconcile();
  }

  Future<String?> contentOf(String id) async {
    final rows = await (db.select(
      db.messages,
    )..where((m) => m.id.equals(id))).get();
    return rows.isEmpty ? null : rows.single.content;
  }

  /// How the store differs from the server, or null when it does not.
  Future<String?> disagreement() async {
    final held = {
      for (final row in await db.select(db.messages).get())
        if (row.seq > 0) row.id: row,
    };
    final live = {for (final m in server.live) m.id: m};
    for (final row in held.values) {
      final standing = live[row.id];
      if (standing == null) {
        return '${row.id} is held but the server deleted it';
      }
      if (standing.content != row.content) {
        return '${row.id} reads "${row.content}", the server "${standing.content}"';
      }
    }
    if (live.isNotEmpty && held.isEmpty) return 'nothing is held';
    if (held.isEmpty) return null;
    final oldest = held.values.map((r) => r.seq).reduce(min);
    for (final m in live.values) {
      if (m.seq >= oldest && !held.containsKey(m.id)) {
        return '${m.id} (seq ${m.seq}) is missing above the oldest held row';
      }
    }
    final opCursor = await store.opCursorFor(server.channelId);
    if (opCursor != server.opHead) {
      return 'the op cursor is $opCursor, the head ${server.opHead}';
    }
    return null;
  }
}
