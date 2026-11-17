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
///
/// A sound server restart ends `pactl subscribe` mid-call, so it is started
/// again after [restartAfter], doubling up to [_restartCap], while anyone listens.
PactlSubscriber sharedWhileListened(
  PactlSubscriber source, {
  Duration restartAfter = const Duration(seconds: 1),
}) {
  StreamSubscription<String>? upstream;
  Timer? restart;
  var delay = restartAfter;
  late final StreamController<String> lines;
  void start() {
    upstream = source().listen(
      (line) {
        delay = restartAfter;
        lines.add(line);
      },
      onError: lines.addError,
      onDone: () {
        upstream = null;
        if (!lines.hasListener) return;
        restart = Timer(delay, () {
          restart = null;
          if (lines.hasListener && upstream == null) start();
        });
        delay = delay * 2 > _restartCap ? _restartCap : delay * 2;
      },
    );
  }

  lines = StreamController<String>.broadcast(
    onListen: start,
    onCancel: () {
      restart?.cancel();
      restart = null;
      final ending = upstream;
      upstream = null;
      unawaited(ending?.cancel());
    },
  );
  return () => lines.stream;
}

const _restartCap = Duration(seconds: 30);
