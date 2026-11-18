// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One send at a time per channel, so the server numbers messages in the
/// order they were typed.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs each channel's sends one after another, in the order their slots
/// were taken.
///
/// The server gives a message its `seq` when the request arrives, and
/// concurrent requests arrive in any order, so a fast typist or a bot saw its
/// own messages land shuffled. A failed send never holds up the next one.
class ChannelSendQueue {
  final _tails = <String, Future<void>>{};

  /// Takes [channelId]'s next place in line now, before the caller awaits
  /// anything, so work done ahead of the request cannot reorder the sends.
  SendSlot reserve(String channelId) {
    final previous = _tails[channelId] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[channelId] = tail;
    tail.whenComplete(() {
      if (identical(_tails[channelId], tail)) _tails.remove(channelId);
    });
    return SendSlot._(previous, done);
  }
}

/// One place in a channel's line; the next send waits until it is released.
class SendSlot {
  SendSlot._(this._previous, this._done);

  final Future<void> _previous;
  final Completer<void> _done;

  /// Starts [send] once every earlier slot is released, and releases this one when it settles.
  Future<T> run<T>(Future<T> Function() send) async {
    try {
      await _previous;
      return await send();
    } finally {
      release();
    }
  }

  /// Lets the next send go without this one sending; safe to call again.
  void release() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// The app's one [ChannelSendQueue].
final channelSendQueueProvider = Provider<ChannelSendQueue>(
  (ref) => ChannelSendQueue(),
);
