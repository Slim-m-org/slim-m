// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hand-driven delivery on top of `FuzzWorld`, for tests that pin one
/// interleaving instead of drawing one from a seed.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;

import 'canvas_fuzz_model.dart';
import 'canvas_fuzz_world.dart';

/// The seq an op frame carries, or null for one that carries none.
int? frameSeq(api.ServerEvent event) => switch (event) {
  api.CanvasObjectPlaced(:final object) => object.seq,
  api.CanvasObjectsRemoved(:final seq) => seq,
  api.CanvasCleared(:final seq) => seq,
  api.CanvasObjectsRestored(:final seq) => seq,
  api.CanvasObjectMoved(:final seq) => seq,
  api.CanvasObjectReordered(:final seq) => seq,
  api.CanvasObjectEdited(:final seq) => seq,
  _ => null,
};

/// Hand-driven delivery, for tests that pin one interleaving instead of
/// drawing one from a seed.
extension FuzzScript on FuzzWorld {
  /// The first request [client] has waiting that [match] accepts.
  FuzzPending waiting(FuzzClient client, bool Function(http.Request) match) =>
      client.pending.firstWhere((p) => !p.arrived && match(p.request));

  /// The server acts on [p] now; its reply stays in flight.
  void serverActs(FuzzClient client, FuzzPending p) {
    p.arrived = true;
    p.response = executeFor(client, p.request);
  }

  /// [p]'s reply reaches [client].
  void replyArrives(FuzzClient client, FuzzPending p) {
    client.pending.remove(p);
    final failure = p.failure;
    failure != null
        ? p.completer.completeError(failure)
        : p.completer.complete(p.response);
    flush();
  }

  /// [p]'s reply is lost on the way back: the server acted, the client hears nothing.
  void replyLost(FuzzClient client, FuzzPending p) {
    client.pending.remove(p);
    p.completer.completeError(const SocketLikeFailure());
    flush();
  }

  /// [p] goes through the server and back in one go.
  void roundTrip(FuzzClient client, FuzzPending p) {
    serverActs(client, p);
    replyArrives(client, p);
  }

  /// A cold read of the board, answered right now.
  void readBoard(FuzzClient client) {
    unawaited(client.engine.fetch());
    flush();
    for (final p in client.pending.where((p) => !p.arrived).toList()) {
      if (p.request.url.path.endsWith('/canvas/objects') &&
          p.request.method == 'GET') {
        roundTrip(client, p);
      }
    }
    flush();
  }

  /// Delivers [client]'s frames whose seq is at most [upTo], in order.
  void deliverFramesUpTo(FuzzClient client, int upTo) {
    for (final frame in client.inbox.toList()) {
      final seq = frameSeq(frame.event);
      if (seq != null && seq > upTo) continue;
      client.inbox.remove(frame);
      note('frame -> ${client.userId}: ${FuzzWorld.frameName(frame.event)}');
      client.events.add(frame.event);
      flush();
    }
  }

  /// Delivers only the frame with [seq] that [client] has waiting.
  void deliverSeq(FuzzClient client, int seq) {
    final frame = client.inbox.firstWhere((f) => frameSeq(f.event) == seq);
    client.inbox.remove(frame);
    note('frame -> ${client.userId}: ${FuzzWorld.frameName(frame.event)}');
    client.events.add(frame.event);
    flush();
  }

  /// Delivers every frame [client] has waiting, in order.
  void deliverAllFrames(FuzzClient client) {
    while (client.inbox.isNotEmpty) {
      final frame = client.inbox.removeAt(0);
      note('frame -> ${client.userId}: ${FuzzWorld.frameName(frame.event)}');
      client.events.add(frame.event);
      flush();
    }
  }

  /// Forgets frames [client] has waiting: its socket dropped them.
  void loseFrames(FuzzClient client) => client.inbox.clear();

  /// Runs every request and frame to completion, no faults.
  void quiesce() => settle();

  /// A submit as [actor], straight on the server.
  FuzzSubmit as_(String actor, Map<String, dynamic> body) {
    final result = server.submit(actor, body);
    note(
      '$actor ${body['kind']} -> seq=${result.seq} affected=${result.affected}',
    );
    return result;
  }
}
