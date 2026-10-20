// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A virtual network around real `CanvasEngine`s, for
/// `canvas_engine_fuzz_test.dart`.
///
/// Each [FuzzClient] is a real engine (document, sync, commit queue, ops
/// controller, live-event dispatch) on a `ProviderContainer`. Their HTTP goes
/// to a [FuzzServer]; their WebSocket frames come from its publish hook. The
/// [FuzzWorld] decides, tick by tick, when each request reaches the server,
/// when each reply or frame reaches a client, and what fails: a request dropped
/// before or after the server acted, a rate limit, a reply lost, frames
/// reordered or repeated, a socket that drops for a while. All in virtual
/// time (`fake_async`), so a seed is reproducible.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/testing.dart';

import 'canvas_fuzz_server.dart';
import 'fake_api.dart';
import 'fake_sync.dart';

const String fuzzChannel = 'c1';

http.Response jsonOf(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class FuzzFrame {
  FuzzFrame(this.event);

  final api.ServerEvent event;
}

class FuzzPending {
  FuzzPending(this.request, this.completer);

  final http.Request request;
  final Completer<http.Response> completer;
  http.Response? response;
  Object? failure;
  bool arrived = false;
}

/// How hostile the network is for one run.
class FuzzConfig {
  const FuzzConfig({
    this.dropBefore = 0.04,
    this.dropAfter = 0.04,
    this.rateLimit = 0.04,
    this.duplicateFrame = 0.06,
    this.reorderWindow = 4,
    this.flap = true,
    this.camera = false,
    this.avoid = const {},
  });

  /// A request lost on the way to the server.
  final double dropBefore;

  /// The server acts, the reply is lost.
  final double dropAfter;
  final double rateLimit;
  final double duplicateFrame;
  final int reorderWindow;

  /// Sockets that drop and come back, losing the frames in between.
  final bool flap;

  /// People pan and zoom, so a client holds only part of the board.
  final bool camera;

  /// Behaviours the generator leaves out, so a known failure does not hide
  /// the next one: `previews` (remote drags), `deleteLocked` (Delete on a
  /// locked selection), `foreignEdit` (a note edit the UI would not offer).
  final Set<String> avoid;

  bool allows(String behaviour) => !avoid.contains(behaviour);

  FuzzConfig avoiding(Set<String> more) => FuzzConfig(
    dropBefore: dropBefore,
    dropAfter: dropAfter,
    rateLimit: rateLimit,
    duplicateFrame: duplicateFrame,
    reorderWindow: reorderWindow,
    flap: flap,
    camera: camera,
    avoid: {...avoid, ...more},
  );

  static const calm = FuzzConfig(
    dropBefore: 0,
    dropAfter: 0,
    rateLimit: 0,
    duplicateFrame: 0,
    reorderWindow: 1,
    flap: false,
  );
}

class FuzzClient {
  FuzzClient(this.world, this.index, this.userId, {required this.moderator});

  final FuzzWorld world;
  final int index;
  final String userId;
  final bool moderator;

  final StreamController<api.ServerEvent> events =
      StreamController<api.ServerEvent>.broadcast(sync: true);
  final List<FuzzFrame> inbox = [];
  final List<FuzzPending> pending = [];
  final List<void Function()> script = [];
  bool connected = true;
  int _ids = 0;

  late final ProviderContainer container;
  late final CanvasEngine engine;
  late final ProviderSubscription<CanvasEngineState> _subscription;

  String newId() => '$userId-o${_ids++}';

  void start() {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: api.TokenPair(
              userId: userId,
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        syncControllerProvider.overrideWith(NoopSyncController.new),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride(_handle),
      ],
    );
    _subscription = container.listen(
      canvasEngineProvider(fuzzChannel),
      (_, _) {},
    );
    engine = container.read(canvasEngineProvider(fuzzChannel).notifier);
    engine.document.setViewport(const Size(960, 540));
  }

  void stop() {
    _subscription.close();
    container.dispose();
    unawaited(events.close());
  }

  NoopSyncController get _sync =>
      container.read(syncControllerProvider.notifier) as NoopSyncController;

  void dropSocket() {
    connected = false;
    inbox.clear();
    _sync.report(SyncStatus.offline);
  }

  void restoreSocket() {
    if (connected) return;
    connected = true;
    _sync.report(SyncStatus.live);
  }

  Future<http.Response> _handle(http.Request request) {
    final path = request.url.path;
    if (path.endsWith('/me')) {
      return Future.value(
        jsonOf({
          'id': userId,
          'username': userId,
          'display_name': userId,
          'created_at': 0,
          'permissions': moderator ? Perm.manageCanvas : 0,
        }),
      );
    }
    if (path.endsWith('/permissions')) {
      return Future.value(
        jsonOf({'permissions': moderator ? Perm.manageCanvas : 0}),
      );
    }
    if (path.endsWith('/canvas/media-slots')) {
      return Future.value(jsonOf({'slots': <Object>[]}));
    }
    if (path.endsWith('/canvas/object-locks')) {
      return Future.value(jsonOf({'object_ids': world.server.locked.toList()}));
    }
    if (path.contains('/canvas/objects/') && path.endsWith('/lock')) {
      final id = request.url.pathSegments[request.url.pathSegments.length - 2];
      world.server.setLocked(id, request.method == 'PUT');
      return Future.value(http.Response('', 204));
    }
    if (path.endsWith('/canvas/objects') || path.endsWith('/canvas/ops')) {
      final p = FuzzPending(request, Completer<http.Response>());
      pending.add(p);
      return p.completer.future;
    }
    return Future.value(jsonOf(<Object>[]));
  }
}

class FuzzWorld {
  FuzzWorld(this.seed, this.async, this.config, {int clientCount = 2})
    : rng = math.Random(seed) {
    server = FuzzServer(channelId: fuzzChannel, publish: _publish)
      ..moderators.add('mod');
    for (var i = 0; i < clientCount; i++) {
      final moderator = i == 1;
      final client = FuzzClient(this, i, i == 0 ? 'me' : 'peer$i', moderator: moderator);
      if (moderator) server.moderators.add(client.userId);
      clients.add(client);
    }
    for (final client in clients) {
      client.start();
    }
    flush();
  }

  final int seed;
  final FakeAsync async;
  final FuzzConfig config;
  final math.Random rng;
  late final FuzzServer server;
  final List<FuzzClient> clients = [];
  final List<String> trace = [];
  final List<(int, void Function())> deferred = [];
  int tickNo = 0;
  int _opCounter = 0;

  String newOpId(String who) => '$who-op${_opCounter++}';

  void note(String line) {
    trace.add('[$tickNo] $line');
  }

  void flush() => async.flushMicrotasks();

  void _publish(api.ServerEvent event) {
    for (final client in clients) {
      if (client.connected) client.inbox.add(FuzzFrame(event));
    }
  }

  void publishEphemeral(api.ServerEvent event) => _publish(event);

  // --- the network ---

  void deliverFrame({bool chaos = true}) {
    final candidates = clients.where((c) => c.inbox.isNotEmpty).toList();
    if (candidates.isEmpty) return;
    final client = candidates[rng.nextInt(candidates.length)];
    final window = chaos ? math.min(config.reorderWindow, client.inbox.length) : 1;
    final frame = client.inbox.removeAt(rng.nextInt(window));
    note('frame -> ${client.userId}: ${_name(frame.event)}');
    client.events.add(frame.event);
    if (chaos && rng.nextDouble() < config.duplicateFrame) {
      client.inbox.add(frame);
    }
    flush();
  }

  void arrive({bool chaos = true}) {
    final waiting = [
      for (final c in clients)
        for (final p in c.pending)
          if (!p.arrived) (c, p),
    ];
    if (waiting.isEmpty) return;
    final (client, p) = waiting[rng.nextInt(waiting.length)];
    p.arrived = true;
    final roll = chaos ? rng.nextDouble() : 1.0;
    final label = '${p.request.method} ${p.request.url.path.split('/').last}';
    if (roll < config.dropBefore) {
      p.failure = const SocketLikeFailure();
      note('${client.userId} $label LOST before the server');
      return;
    }
    if (roll < config.dropBefore + config.rateLimit) {
      p.response = jsonOf({'error': 'slow down', 'retry_after_seconds': 1}, 429);
      note('${client.userId} $label rate limited');
      return;
    }
    p.response = _execute(client, p.request);
    note('${client.userId} $label -> ${p.response!.statusCode} ${_summary(p.request)}');
    if (chaos && rng.nextDouble() < config.dropAfter) {
      p.response = null;
      p.failure = const SocketLikeFailure();
      note('${client.userId} $label reply LOST after the server acted');
    }
  }

  void deliverResponse() {
    final ready = [
      for (final c in clients)
        for (final p in c.pending)
          if (p.arrived) (c, p),
    ];
    if (ready.isEmpty) return;
    final (client, p) = ready[rng.nextInt(ready.length)];
    client.pending.remove(p);
    final failure = p.failure;
    if (failure != null) {
      p.completer.completeError(failure);
    } else {
      p.completer.complete(p.response);
    }
    flush();
  }

  http.Response _execute(FuzzClient client, http.Request request) {
    final path = request.url.path;
    try {
      if (request.method == 'GET' && path.endsWith('/canvas/objects')) {
        return jsonOf(server.viewport(request.url.queryParameters));
      }
      if (request.method == 'GET') {
        final after = int.parse(request.url.queryParameters['after_seq']!);
        final limit = (int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100).clamp(1, 200);
        return jsonOf(server.feed(after, limit));
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (path.endsWith('/canvas/objects')) {
        final placed = server.place(
          client.userId,
          body['id'] as String,
          body['kind'] as String,
          (body['x'] as num).toDouble(),
          (body['y'] as num).toDouble(),
          (body['w'] as num).toDouble(),
          (body['h'] as num).toDouble(),
          Map<String, dynamic>.from(body['props'] as Map),
        );
        return jsonOf(placed.object.toJson(), 201);
      }
      return jsonOf(server.opResultJson(server.submit(client.userId, body)), 201);
    } on FuzzRefusal catch (refusal) {
      return jsonOf({'error': refusal.message}, refusal.status);
    }
  }

  // --- time and faults ---

  void elapse([int? ms]) {
    async.elapse(Duration(milliseconds: ms ?? 30 + rng.nextInt(700)));
    flush();
  }

  void flap() {
    if (!config.flap) return;
    final client = clients[rng.nextInt(clients.length)];
    if (client.connected) {
      note('${client.userId} socket DROPPED');
      client.dropSocket();
    } else {
      note('${client.userId} socket back');
      client.restoreSocket();
    }
    flush();
  }

  void runDeferred() {
    for (final entry in [...deferred]) {
      if (entry.$1 > tickNo) continue;
      deferred.remove(entry);
      entry.$2();
    }
    flush();
  }

  /// One pass that moves everything in flight forward without faults.
  bool _drainOnce() {
    var moved = false;
    while (clients.any((c) => c.pending.any((p) => !p.arrived))) {
      arrive(chaos: false);
      moved = true;
    }
    while (clients.any((c) => c.pending.any((p) => p.arrived))) {
      deliverResponse();
      moved = true;
    }
    while (clients.any((c) => c.inbox.isNotEmpty)) {
      deliverFrame(chaos: false);
      moved = true;
    }
    for (final entry in [...deferred]) {
      deferred.remove(entry);
      entry.$2();
      moved = true;
    }
    return moved;
  }

  /// Everything delivered, in order, with no more faults, and enough virtual
  /// time for every timer the engines hold to fire.
  void settle() {
    for (final client in clients) {
      client.restoreSocket();
      client.script.clear();
    }
    flush();
    var quiet = 0;
    for (var round = 0; round < 400 && quiet < 6; round++) {
      quiet = _drainOnce() ? 0 : quiet + 1;
      elapse(1500);
    }
    elapse(30000);
    for (var round = 0; round < 40 && _drainOnce(); round++) {
      elapse(2000);
    }
  }

  void dispose() {
    for (final client in clients) {
      client.stop();
    }
  }

  static String _name(api.ServerEvent e) => switch (e) {
    api.CanvasObjectPlaced(:final object) => 'placed ${object.id} seq=${object.seq}',
    api.CanvasObjectsRemoved(:final seq, :final objectIds) => 'removed seq=$seq $objectIds',
    api.CanvasCleared(:final seq, :final beforeSeq, :final scope) =>
      'cleared seq=$seq <=$beforeSeq kinds=${scope.kinds} author=${scope.authorId}',
    api.CanvasObjectsRestored(:final seq, :final objectIds) => 'restored seq=$seq $objectIds',
    api.CanvasObjectMoved(:final seq, :final objectId) => 'moved seq=$seq $objectId',
    api.CanvasObjectReordered(:final seq, :final objectId, :final zIndex) =>
      'reordered seq=$seq $objectId z=$zIndex',
    api.CanvasObjectEdited(:final seq, :final objectId) => 'edited seq=$seq $objectId',
    api.CanvasObjectPreview(:final objectId, :final ended) => 'preview $objectId ended=$ended',
    api.CanvasObjectLockChanged(:final objectId, :final locked) => 'lock $objectId=$locked',
    _ => e.runtimeType.toString(),
  };

  static String _summary(http.Request r) {
    if (r.method == 'GET') return r.url.queryParameters.toString();
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final keys = {
      for (final k in ['kind', 'id', 'object_id', 'object_ids', 'before_seq', 'target_op', 'z_index'])
        if (body.containsKey(k)) k: body[k],
    };
    return keys.toString();
  }
}

/// A request lost in transit; the transport turns it into a TransportException.
class SocketLikeFailure implements Exception {
  const SocketLikeFailure();

  @override
  String toString() => 'connection reset';
}
