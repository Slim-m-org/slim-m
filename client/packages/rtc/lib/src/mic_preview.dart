// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live microphone level outside a call, for setup and Voice settings.
library;

import 'dart:async';

import 'input_gate.dart' show kInputFloorDb;

enum MicPreviewStatus {
  /// Nothing is capturing.
  idle,

  /// The capture is being opened.
  opening,

  /// Capturing; [MicPreviewReading.levelDb] is live.
  live,

  /// The capture could not be opened or stopped reporting.
  unavailable,
}

class MicPreviewReading {
  const MicPreviewReading(
    this.status, {
    this.levelDb = kInputFloorDb,
    this.voice = false,
  });

  final MicPreviewStatus status;
  final double levelDb;

  /// Whether the native gate heard speech; false where there is no gate.
  final bool voice;
}

/// One capture the preview owns, opened and closed in order.
abstract interface class MicPreviewSource {
  Future<void> open(String? deviceId);

  /// The latest level and voice state, or null when none can be read.
  Future<({double levelDb, bool voice})?> read();

  Future<void> close();
}

/// Opens [source] on demand and polls it; every open and close runs after the
/// one before it, so switching device never has two captures at once.
class MicPreview {
  MicPreview({
    required MicPreviewSource source,
    this.interval = const Duration(milliseconds: 50),
    this.maxMisses = 40,
    this.openTimeout = const Duration(seconds: 10),
  }) : _source = source;

  final Duration interval;

  /// Consecutive empty reads before the preview calls itself unavailable.
  final int maxMisses;

  /// A capture that never finishes opening reads as unavailable, not as opening forever.
  final Duration openTimeout;
  final MicPreviewSource _source;
  Future<void> _queue = Future<void>.value();
  final _readings = StreamController<MicPreviewReading>.broadcast();
  MicPreviewReading _current = const MicPreviewReading(MicPreviewStatus.idle);
  Timer? _timer;
  Timer? _openTimer;
  Completer<void>? _opening;
  int _generation = 0;
  int _misses = 0;
  bool _polling = false;

  MicPreviewReading get current => _current;
  Stream<MicPreviewReading> get readings => _readings.stream;

  /// Starts capturing [deviceId] (null for the system default), replacing any
  /// capture already running.
  Future<void> start(String? deviceId) {
    final mine = ++_generation;
    _stopTimer();
    _emit(const MicPreviewReading(MicPreviewStatus.opening));
    return _enqueue(() async {
      await _source.close();
      if (mine != _generation) return;
      try {
        await _openWithin(deviceId);
      } on Object {
        if (mine == _generation) {
          _emit(const MicPreviewReading(MicPreviewStatus.unavailable));
        }
        await _source.close();
        return;
      }
      if (mine != _generation) {
        await _source.close();
        return;
      }
      _misses = 0;
      _timer = Timer.periodic(interval, (_) => unawaited(_poll(mine)));
    });
  }

  Future<void> stop() {
    _generation++;
    _stopTimer();
    _emit(const MicPreviewReading(MicPreviewStatus.idle));
    return _enqueue(_source.close);
  }

  Future<void> dispose() async {
    await stop();
    await _readings.close();
  }

  Future<void> _enqueue(Future<void> Function() job) =>
      _queue = _queue.then((_) => job(), onError: (_) => job());

  /// Fails the open after [openTimeout] with a timer [stop] can cancel, so no timer outlives the preview.
  Future<void> _openWithin(String? deviceId) {
    final done = Completer<void>();
    _cancelOpen();
    _opening = done;
    _openTimer = Timer(openTimeout, () {
      if (!done.isCompleted) {
        done.completeError(TimeoutException('microphone open', openTimeout));
      }
    });
    _source.open(deviceId).then(
      (_) {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    return done.future.whenComplete(() {
      if (identical(_opening, done)) {
        _openTimer?.cancel();
        _openTimer = null;
        _opening = null;
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _cancelOpen();
  }

  /// Ends a pending open as failed, so a stop never leaves the job queue waiting on it.
  void _cancelOpen() {
    _openTimer?.cancel();
    _openTimer = null;
    final pending = _opening;
    _opening = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('microphone open cancelled'));
    }
  }

  Future<void> _poll(int mine) async {
    if (_polling) return;
    _polling = true;
    try {
      final read = await _source.read();
      if (mine != _generation) return;
      if (read == null) {
        if (++_misses >= maxMisses) {
          _stopTimer();
          _emit(const MicPreviewReading(MicPreviewStatus.unavailable));
          await _enqueue(_source.close);
        }
        return;
      }
      _misses = 0;
      _emit(MicPreviewReading(
        MicPreviewStatus.live,
        levelDb: read.levelDb,
        voice: read.voice,
      ));
    } on Object {
      if (mine != _generation) return;
      _stopTimer();
      _emit(const MicPreviewReading(MicPreviewStatus.unavailable));
      await _enqueue(_source.close);
    } finally {
      _polling = false;
    }
  }

  void _emit(MicPreviewReading next) {
    _current = next;
    if (!_readings.isClosed) _readings.add(next);
  }
}
