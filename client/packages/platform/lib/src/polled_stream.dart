// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared shape of a rich-presence source: nothing runs until someone
/// listens, and cancelling stops every read (decision 0044).
library;

import 'dart:async';

/// Thrown by a read that has no fresh answer (a rate limit, say), so the
/// last value stands instead of flickering to null.
class PollSkip implements Exception {
  const PollSkip();
}

/// Reads now and then every [interval], emitting only when the answer
/// changes. Any other failure reads as "nothing", never as an error.
///
/// A tick that finds the previous read still running is skipped, and a read
/// past [readTimeout] counts as a failure, so a hung source cannot pile up reads.
/// Cancelling waits out a read already running, up to [cancelGrace], so a
/// read part way through a sequence of requests finishes before cancel
/// resolves, without a hung one holding cancel hostage.
Stream<T?> polledStream<T>({
  required Duration interval,
  required Future<T?> Function() read,
  Future<void> Function()? onCancel,
  Duration readTimeout = const Duration(seconds: 30),
  Duration cancelGrace = const Duration(seconds: 1),
}) {
  Timer? timer;
  T? last;
  var first = true;
  late final StreamController<T?> controller;

  Future<T?>? inFlight;

  Future<void> poll() async {
    if (inFlight != null || controller.isClosed) return;
    final reading = read().timeout(readTimeout);
    inFlight = reading;
    T? current;
    try {
      current = await reading;
    } on PollSkip {
      return;
    } on Object {
      current = null;
    } finally {
      inFlight = null;
    }
    if (controller.isClosed || (!first && current == last)) return;
    first = false;
    last = current;
    controller.add(current);
  }

  controller = StreamController<T?>(
    onListen: () {
      unawaited(poll());
      timer = Timer.periodic(interval, (_) => unawaited(poll()));
    },
    onCancel: () async {
      timer?.cancel();
      try {
        await inFlight?.timeout(cancelGrace);
      } on Object {
        // The read's outcome no longer matters to anyone.
      }
      await onCancel?.call();
    },
  );
  return controller.stream;
}
