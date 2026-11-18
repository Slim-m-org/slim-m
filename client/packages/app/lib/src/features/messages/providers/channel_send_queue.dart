// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One send at a time per channel, so the server numbers messages in the
/// order they were typed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs each channel's sends one after another, in the order they were queued.
///
/// The server gives a message its `seq` when the request arrives, and
/// concurrent requests arrive in any order, so a fast typist or a bot saw its
/// own messages land shuffled. A failed send never holds up the next one.
class ChannelSendQueue {
  final _tails = <String, Future<void>>{};

  /// Starts [send] once every earlier send in [channelId] has settled.
  Future<T> run<T>(String channelId, Future<T> Function() send) {
    final previous = _tails[channelId] ?? Future<void>.value();
    final result = previous.then((_) => send());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _tails[channelId] = tail;
    tail.whenComplete(() {
      if (identical(_tails[channelId], tail)) _tails.remove(channelId);
    });
    return result;
  }
}

/// The app's one [ChannelSendQueue].
final channelSendQueueProvider = Provider<ChannelSendQueue>(
  (ref) => ChannelSendQueue(),
);
