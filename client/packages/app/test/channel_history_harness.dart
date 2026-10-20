// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real [ChannelScreen] over a real local store and a fake server that
/// answers `GET /channels/{id}/messages` the way the real one does: newest
/// first, keyset-paginated on `seq`, capped by `limit`.
///
/// Paging backwards and knowing where a channel starts are both answers the
/// client can only get from that endpoint's shape, so a fake that returned a
/// fixed list would prove nothing about either.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_page_size.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/rate_limit_retry.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

/// Stands in for the real [SyncController]; see `channel_screen_test.dart`,
/// which needs the same seam for the same reason.
///
/// Reports [_status] from `start` rather than leaving it at the base
/// constructor's initial `offline`: the empty-transcript synthesis in
/// `channel_screen.dart` only fires at [SyncStatus.live], and nothing else in
/// this harness can ever move it there.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref, this._status);

  final SyncStatus _status;

  @override
  Future<void> start() async {
    state = _status;
  }
}

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message channelMessage(int seq, {String authorId = 'alice'}) => api.Message(
  id: 'm$seq',
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorId,
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

/// A bounded pump count rather than `pumpAndSettle`, which never returns
/// here: `AppButton`'s hover and focus machinery keeps a frame scheduled.
Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// The transcript's own [ScrollController], the same instance `ChannelScreen`
/// drives internally, so moving it here is what a real drag would do.
ScrollController transcriptScroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

/// How many rows the transcript was handed, the top slot included. The list
/// builds lazily, so this is the only viewport-independent measure of how
/// much history actually reached it.
int transcriptItemCount(WidgetTester tester) {
  final list = tester.widget<ListView>(find.byType(ListView));
  return (list.childrenDelegate as SliverChildBuilderDelegate).childCount!;
}

/// Puts the reader at the oldest end. The list is reversed, so that is the
/// maximum extent, not the minimum.
///
/// Repeated because a lazy [ListView] only estimates its maximum extent from
/// the slivers it has built, so one jump lands short of the real end and the
/// row the tests care about is never laid out.
Future<void> scrollToOldest(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final position = transcriptScroll(tester).position;
    if (position.pixels >= position.maxScrollExtent) break;
    position.jumpTo(position.maxScrollExtent);
    await flush(tester);
  }
}

class HistoryHarness {
  HistoryHarness({
    required this.db,
    required this.store,
    required this.container,
    required this.historyRequests,
    required this.userRequests,
    required this.rateLimitWaits,
    required Completer<void>? gate,
  }) : _gate = gate;

  final SlimmDatabase db;
  final MessageStore store;
  final ProviderContainer container;

  /// Every `GET .../messages` this screen made, in order, so a test can say
  /// what was asked for as well as what came back.
  final List<Uri> historyRequests;

  /// Every `GET /users` and `GET /users/{id}` this screen made, so a test can
  /// count what resolving a page of authors cost.
  final List<Uri> userRequests;

  /// How long each rate-limit retry was asked to wait; nothing really sleeps.
  final List<Duration> rateLimitWaits;

  final Completer<void>? _gate;

  /// Lets a held backwards page answer. Until this is called the reader stays
  /// at the top of the list with the page still in flight, which is the only
  /// moment a test can look at what stands above the oldest loaded row.
  void releaseOlderPages() => _gate?.complete();

  /// The `before` cursor of every backwards page actually requested, in
  /// order, ignoring the plain `listMessages(limit: 50)` hydration fetch that
  /// carries none. What a test cares about when counting pages is this, not
  /// [historyRequests] itself, which also carries that one non-paging call.
  List<String?> get beforeCursors => historyRequests
      .where((u) => u.queryParameters.containsKey('before'))
      .map((u) => u.queryParameters['before'])
      .toList();
}

/// Mounts the screen with [serverSeqs] existing server-side and only
/// [seededSeqs] already in the local store, which is the state a client is in
/// after `/sync` or the screen's own 50-message hydration.
///
/// With [holdOlderPages] set, any request carrying a `before` cursor waits for
/// [HistoryHarness.releaseOlderPages]; a page that lands immediately grows the
/// list out from under the reader, which moves the top back off screen before
/// anything can be asserted about it. With [olderPagesFail] set, those same
/// requests are refused.
///
/// [messageAuthorId] names who every message in the channel is from, seeded
/// and server-side alike; [blockedUserIds] is who this viewer has blocked, so
/// a test can put the two together and mount a channel that is entirely
/// filtered from view. [syncStatus] is what [SyncController] reports once
/// `start` runs, since nothing else in this harness can move it off `offline`.
/// [storeFactory] swaps in a [MessageStore] subclass, for a test that needs
/// the store itself to misbehave rather than the network.
Future<HistoryHarness> mountChannel(
  WidgetTester tester, {
  required List<int> serverSeqs,
  required List<int> seededSeqs,
  bool holdOlderPages = false,
  bool olderPagesFail = false,
  String messageAuthorId = 'alice',
  List<String> blockedUserIds = const [],
  SyncStatus syncStatus = SyncStatus.offline,
  MessageStore Function(SlimmDatabase db)? storeFactory,
  List<Map<String, dynamic>> searchHits = const [],
  MessagePageSize messagePageSize = defaultMessagePageSize,
  String Function(int seq)? authorFor,
  int olderPageRateLimits = 0,
  int? rateLimitRetryAfter,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = (storeFactory ?? MessageStore.new)(db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages(
    seededSeqs.map(
      (seq) => channelMessage(
        seq,
        authorId: authorFor?.call(seq) ?? messageAuthorId,
      ),
    ),
  );

  final requests = <Uri>[];
  final userRequests = <Uri>[];
  final waits = <Duration>[];
  final server = _FakeServer(
    serverSeqs: serverSeqs,
    requests: requests,
    userRequests: userRequests,
    gate: holdOlderPages ? Completer<void>() : null,
    olderPagesFail: olderPagesFail,
    olderPageRateLimits: olderPageRateLimits,
    rateLimitRetryAfter: rateLimitRetryAfter,
    authorFor: authorFor ?? (_) => messageAuthorId,
    blockedUserIds: blockedUserIds,
    searchHits: searchHits,
  );
  final container = ProviderContainer(
    overrides: [
      ...overrides,
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      messagePageSizeControllerProvider.overrideWith(
        (ref) => MessagePageSizeController(ref, messagePageSize),
      ),
      storeProvider.overrideWith((ref) async => store),
      rateLimitWaitProvider.overrideWithValue((d) async => waits.add(d)),
      syncControllerProvider.overrideWith(
        (ref) => _NoopSyncController(ref, syncStatus),
      ),
      mockApiOverride(server.answer),
    ],
  );
  addTearDown(container.dispose);

  // A real GoRouter, not a bare MaterialApp: jumping from a tapped search result reads it.
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) =>
            const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await flush(tester);

  return HistoryHarness(
    db: db,
    store: store,
    container: container,
    historyRequests: requests,
    userRequests: userRequests,
    rateLimitWaits: waits,
    gate: server.gate,
  );
}

/// The fake server behind [mountChannel]; a class so a new behaviour is a
/// field, not another positional parameter.
class _FakeServer {
  _FakeServer({
    required this.serverSeqs,
    required this.requests,
    required this.userRequests,
    required this.gate,
    required this.olderPagesFail,
    required this.olderPageRateLimits,
    required this.rateLimitRetryAfter,
    required this.authorFor,
    required this.blockedUserIds,
    required this.searchHits,
  });

  final List<int> serverSeqs;
  final List<Uri> requests;
  final List<Uri> userRequests;
  final Completer<void>? gate;
  final bool olderPagesFail;
  final int olderPageRateLimits;
  final int? rateLimitRetryAfter;
  final String Function(int seq) authorFor;
  final List<String> blockedUserIds;
  final List<Map<String, dynamic>> searchHits;
  int _rateLimited = 0;

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.startsWith('/users')) {
      userRequests.add(request.url);
    }
    if (request.method == 'GET' && path == '/channels/c1/messages/search') {
      return _jsonBody(searchHits);
    }
    if (request.method == 'GET' && path == '/channels/c1/messages') {
      requests.add(request.url);
      final older = request.url.queryParameters.containsKey('before');
      if (gate != null && older) await gate!.future;
      if (older && _rateLimited < olderPageRateLimits) {
        _rateLimited++;
        return http.Response(
          jsonEncode({
            'error': 'rate limited',
            if (rateLimitRetryAfter != null)
              'retry_after_seconds': rateLimitRetryAfter,
          }),
          429,
          headers: {
            'content-type': 'application/json',
            if (rateLimitRetryAfter != null)
              'retry-after': '$rateLimitRetryAfter',
          },
        );
      }
      if (olderPagesFail && older) {
        return http.Response(
          jsonEncode({'error': 'nope'}),
          500,
          headers: {'content-type': 'application/json'},
        );
      }
      return _jsonBody(_page(request.url, serverSeqs, authorFor));
    }
    if (request.method == 'GET' && path == '/me') return _jsonBody(_meJson());
    if (request.method == 'GET' && path == '/blocks') {
      return _jsonBody(blockedUserIds);
    }
    if (request.method == 'PUT' && path == '/channels/c1/read') {
      return _jsonBody({'last_read_seq': 0, 'unread': 0});
    }
    if (_answersEmpty(request.method, path)) {
      return _jsonBody(const <Object>[]);
    }
    throw StateError(
      'channel_history_harness._FakeServer has no route for ${request.method} '
      '$path - add it to _answersEmpty if an empty body is legitimate, or '
      'answer it explicitly if a test now depends on its content',
    );
  }
}

/// Routes this harness legitimately answers empty for: side-channel lookups
/// (permissions, pins, members, the emoji/user directories, avatars,
/// `/version`) that none of the tests built on this harness inspect the
/// content of.
///
/// An explicit allowlist rather than a silent catch-all, so a route string
/// drifting out from under a future test that *does* assert on one of these
/// - pins or members content, say - fails loudly here instead of passing
/// vacuously against an empty list.
bool _answersEmpty(String method, String path) {
  const exact = {
    'GET /channels/c1/permissions',
    'GET /channels/c1/pins',
    'GET /emoji',
    'GET /members',
    'GET /users',
    'GET /version',
  };
  if (exact.contains('$method $path')) return true;
  return method == 'GET' && RegExp(r'^/users/[^/]+(/avatar)?$').hasMatch(path);
}

/// The server's own contract: live messages with `seq` below `before`,
/// newest first, at most `limit` of them.
List<Map<String, dynamic>> _page(
  Uri url,
  List<int> serverSeqs,
  String Function(int seq) authorFor,
) {
  final before = int.tryParse(url.queryParameters['before'] ?? '');
  final limit = int.tryParse(url.queryParameters['limit'] ?? '') ?? 50;
  final seqs = serverSeqs.where((s) => before == null || s < before).toList()
    ..sort((a, b) => b.compareTo(a));
  return [
    for (final seq in seqs.take(limit))
      _messageJson(channelMessage(seq, authorId: authorFor(seq))),
  ];
}

Map<String, dynamic> _messageJson(api.Message message) => {
  'id': message.id,
  'channel_id': message.channelId,
  'author_id': message.authorId,
  'author_display_name': message.authorDisplayName,
  'seq': message.seq,
  'content': message.content,
  'created_at': message.createdAt,
};

http.Response _jsonBody(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);
