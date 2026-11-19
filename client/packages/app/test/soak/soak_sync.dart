// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sync controller the soak script feeds by hand, and a live-event stream
/// that counts who is listening to it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import 'soak_census.dart';

/// Live at once, with no socket; [deliver] is the socket.
class SoakSyncController extends SyncController {
  SoakSyncController(this._soakRef, this._listeners) : super(_soakRef);

  final Ref _soakRef;
  final OriginCensus _listeners;
  final _frames = StreamController<ServerEvent>.broadcast();
  late final Stream<ServerEvent> _counted = CountedStream(
    _frames.stream,
    _listeners,
  );

  @override
  Stream<ServerEvent> get liveEvents => _counted;

  @override
  Future<void> start() async {
    // Past a real await, or Riverpod refuses the write as one provider initialising another.
    await Future<void>.value();
    if (!mounted) return;
    state = SyncStatus.live;
    _soakRef.read(initialSyncCompleteProvider.notifier).state = true;
  }

  @override
  Future<void> stop() async {
    if (mounted) state = SyncStatus.offline;
  }

  /// One frame off the socket: broadcast first, then applied, as the real listener does.
  Future<void> deliver(ServerEvent event) async {
    if (!mounted) return;
    _frames.add(event);
    await applyServerEventForTest(event);
  }

  @override
  void dispose() {
    unawaited(_frames.close());
    super.dispose();
  }
}

/// A broadcast stream that records every open subscription and where it was made.
class CountedStream<T> extends Stream<T> {
  CountedStream(this._inner, this._census);

  final Stream<T> _inner;
  final OriginCensus _census;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final inner = _inner.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    final token = _census.open(StackTrace.current);
    return _CountedSubscription(inner, () => _census.close(token));
  }
}

class _CountedSubscription<T> implements StreamSubscription<T> {
  _CountedSubscription(this._inner, this._closed);

  final StreamSubscription<T> _inner;
  final void Function() _closed;

  @override
  Future<void> cancel() {
    _closed();
    return _inner.cancel();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
  @override
  bool get isPaused => _inner.isPaused;
  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);
  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);
  @override
  void onError(Function? handleError) => _inner.onError(handleError);
  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);
  @override
  void resume() => _inner.resume();
}
