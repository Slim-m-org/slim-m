// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a blocked share's audio unsubscribed without repeating a request the SFU has not answered yet.
library;

import 'dart:async';

class ShareAudioGate {
  ShareAudioGate({required this.onError});

  final void Function(Object error) onError;

  /// The direction last requested per sid, until the publication's state flips or the request fails.
  final _inFlight = <String, bool>{};

  /// Subscribes or unsubscribes one share-audio publication to match [blocked].
  void apply({
    required String sid,
    required bool blocked,
    required bool subscribed,
    required Future<void> Function() subscribe,
    required Future<void> Function() unsubscribe,
  }) {
    if (blocked == !subscribed) {
      _inFlight.remove(sid);
      return;
    }
    if (_inFlight[sid] == blocked) return;
    _inFlight[sid] = blocked;
    unawaited(
      (blocked ? unsubscribe() : subscribe()).catchError((Object error) {
        _inFlight.remove(sid);
        onError(error);
      }),
    );
  }
}
