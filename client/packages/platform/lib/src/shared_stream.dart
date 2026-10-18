// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One upstream read shared by every listener, so a source costs the same
/// whether one account or five are watching it.
library;

import 'dart:async';

import 'game_source.dart';
import 'now_playing.dart';

/// Opens [open] when the first listener arrives and cancels it when the last
/// leaves; a late listener is handed the latest value at once rather than
/// waiting a whole poll interval for it.
class SharedStream<T> {
  SharedStream(this._open, {this.onIdle});

  final Stream<T?> Function() _open;

  /// Called after the last listener left and the upstream was cancelled.
  final void Function()? onIdle;

  StreamSubscription<T?>? _upstream;
  var _hasLast = false;
  T? _last;
  late final StreamController<T?> _controller = StreamController<T?>.broadcast(
    onListen: () => _upstream = _attach(),
    onCancel: () async {
      final upstream = _upstream;
      _upstream = null;
      _hasLast = false;
      _last = null;
      await upstream?.cancel();
      if (!_controller.hasListener) onIdle?.call();
    },
  );

  StreamSubscription<T?> _attach() => _open().listen((value) {
        _hasLast = true;
        _last = value;
        _controller.add(value);
      }, onError: _controller.addError);

  /// Swaps the upstream for a fresh one, for when what [_open] reads from changed.
  Future<void> reopen() async {
    final old = _upstream;
    if (old == null) return;
    _upstream = _attach();
    await old.cancel();
  }

  Stream<T?> get stream => Stream<T?>.multi((out) {
        if (_hasLast) out.add(_last);
        final sub = _controller.stream.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
        out.onCancel = sub.cancel;
      });
}

class SharedNowPlayingSource implements NowPlayingSource {
  SharedNowPlayingSource(NowPlayingSource inner)
      : _shared = SharedStream<NowPlaying>(inner.watch);

  final SharedStream<NowPlaying> _shared;

  @override
  Stream<NowPlaying?> watch() => _shared.stream;
}

class SharedGameSource implements GameSource {
  SharedGameSource(GameSource inner)
      : _shared = SharedStream<RunningGame>(inner.watch);

  final SharedStream<RunningGame> _shared;

  @override
  Stream<RunningGame?> watch() => _shared.stream;
}
