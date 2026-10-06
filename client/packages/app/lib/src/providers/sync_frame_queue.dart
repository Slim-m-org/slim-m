// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One socket's frames, applied one at a time and in arrival order.
library;

import 'dart:async';
import 'dart:collection';

import 'package:slimm_api/api.dart' as api;

/// Thrown when the socket closes before the connect that opened it finished.
///
/// While a connect is in flight the controller is `connecting`, which its
/// ordinary drop handling ignores, so this is how the loss reaches `start()`.
class SocketClosedDuringConnect implements Exception {
  const SocketClosedDuringConnect();

  @override
  String toString() => 'the socket closed before the connect finished';
}

/// Serialises the handling of one socket's frames.
///
/// `Stream.listen` does not wait for an async listener, so without this every
/// frame is handled while the previous one is still awaiting the store, and a
/// handler that reads a cursor, decides and writes it back races the next
/// frame's read. It also holds frames back until [flush], which is how a
/// connect keeps what the socket delivers while it catches up over REST.
class SerialFrameQueue {
  SerialFrameQueue(this._handle, {required this.onError});

  final Future<void> Function(api.ServerEvent event) _handle;

  /// Called for a handler that fails once the queue is live; before that the
  /// failure is thrown out of [flush] to the connect that is draining it.
  final void Function(Object error, StackTrace stack) onError;

  final _pending = Queue<api.ServerEvent>();
  bool _held = true;
  bool _pumping = false;

  /// Whether the socket behind this queue has closed.
  bool closed = false;

  void add(api.ServerEvent event) {
    _pending.add(event);
    if (!_held) unawaited(_pump());
  }

  /// Applies everything held so far, in order, then goes live.
  ///
  /// A frame arriving while this drains joins the same drain, and the switch
  /// to live happens with no await after the last emptiness check, so no frame
  /// can fall between the drain and the live pump.
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await _handle(_pending.removeFirst());
    }
    _held = false;
  }

  /// Drops what is still waiting, for a socket that is being torn down.
  void clear() => _pending.clear();

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        try {
          await _handle(_pending.removeFirst());
        } catch (error, stack) {
          onError(error, stack);
        }
      }
    } finally {
      _pumping = false;
    }
  }
}
