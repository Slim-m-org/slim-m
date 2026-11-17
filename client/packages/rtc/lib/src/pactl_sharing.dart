// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One `pactl` process where several callers ask the same thing at once.
///
/// Every spawn forks the app on its UI thread, and joining a call asked the
/// sound server for the same device list three times in the same instant
/// and started two `pactl subscribe` processes; see `pulse_audio_io.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'pulse_audio_io.dart' show PactlRunner, PactlSubscriber;

/// Device queries whose answer a caller that asks while one runs can share:
/// a device that appears meanwhile also raises a change event, which asks again.
/// Stream lists are left out, since a new stream must never miss its own move.
bool _shareable(List<String> args) => switch (args) {
      ['-f', 'json', 'list', 'sources' || 'sinks'] => true,
      ['get-default-source' || 'get-default-sink'] => true,
      _ => false,
    };

/// [run], with a shareable query that is already running answered by that run.
PactlRunner sharingDeviceQueries(PactlRunner run) {
  final running = <String, Future<ProcessResult>>{};
  return (args) {
    if (!_shareable(args)) return run(args);
    final key = args.join(' ');
    return running[key] ??= run(args).whenComplete(() {
      running.remove(key);
    });
  };
}

/// One subscription to [source] however many listen, held while anyone does.
PactlSubscriber sharedWhileListened(PactlSubscriber source) {
  StreamSubscription<String>? upstream;
  late final StreamController<String> lines;
  lines = StreamController<String>.broadcast(
    onListen: () => upstream = source().listen(
      lines.add,
      onError: lines.addError,
      onDone: () => upstream = null,
    ),
    onCancel: () {
      final ending = upstream;
      upstream = null;
      unawaited(ending?.cancel());
    },
  );
  return () => lines.stream;
}
