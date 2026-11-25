// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One `pactl` process where several callers ask the same thing at once.
///
/// Every spawn forks the app on its UI thread, and joining a call asked the
/// sound server for the same device list three times in the same instant
/// and started two `pactl subscribe` processes; see `pulse_audio_io.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'pulse_audio_io.dart'
    show PactlRunner, PactlSubscriber, pactlTimedOutExit;

/// Device queries whose answer a caller that asks while one runs can share:
/// a device that appears meanwhile also raises a change event, which asks again.
/// Stream lists are left out, since a new stream must never miss its own move.
bool _shareable(List<String> args) => switch (args) {
      ['-f', 'json', 'list', 'sources' || 'sinks'] => true,
      ['get-default-source' || 'get-default-sink'] => true,
      _ => false,
    };

/// [run], with a shareable query that is already running answered by that run.
///
/// A query that outlasts [within] answers a non-zero exit and is forgotten, so a
/// wedged sound server cannot keep every later identical query waiting on it.
PactlRunner sharingDeviceQueries(
  PactlRunner run, {
  Duration within = const Duration(seconds: 4),
}) {
  final running = <String, Future<ProcessResult>>{};
  Future<ProcessResult> bounded(List<String> args) => boundedBy(
        run(args),
        within,
        () => ProcessResult(0, pactlTimedOutExit, '', 'timed out'),
      );
  return (args) {
    if (!_shareable(args)) return bounded(args);
    final key = args.join(' ');
    return running[key] ??= bounded(args).whenComplete(() {
      running.remove(key);
    });
  };
}

/// [pending], or [onTimeout]'s answer once [within] has passed.
///
/// Both the clock and the answer run in the root zone, as the process's own completion does,
/// so a widget test's fake clock sees neither.
Future<T> boundedBy<T>(
  Future<T> pending,
  Duration within,
  T Function() onTimeout,
) {
  final done = Completer<T>();
  final timer = Zone.root.createTimer(within, () {
    if (!done.isCompleted) done.complete(onTimeout());
  });
  Zone.root.run(() {
    pending.then<void>((value) {
      timer.cancel();
      if (!done.isCompleted) done.complete(value);
    }, onError: (Object error, StackTrace stack) {
      timer.cancel();
      if (!done.isCompleted) done.completeError(error, stack);
    });
  });
  return done.future;
}

/// One subscription to [source] however many listen, held while anyone does.
///
/// A sound server restart ends `pactl subscribe` mid-call, so it is started
/// again after [restartAfter], doubling up to [_restartCap], while anyone listens.
/// A host where it never delivered a line has no working `pactl`, so it is not retried.
PactlSubscriber sharedWhileListened(
  PactlSubscriber source, {
  Duration restartAfter = const Duration(seconds: 1),
}) {
  StreamSubscription<String>? upstream;
  Timer? restart;
  var delay = restartAfter;
  var everHeard = false;
  late final StreamController<String> lines;
  void start() {
    upstream = source().listen(
      (line) {
        delay = restartAfter;
        everHeard = true;
        lines.add(line);
      },
      onError: lines.addError,
      onDone: () {
        upstream = null;
        if (!lines.hasListener || !everHeard) return;
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
