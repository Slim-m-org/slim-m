// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ends a share whose window or screen went away, instead of leaving receivers a frozen picture.
library;

import 'dart:async';

import 'screen_share_local.dart';

class ShareSourceWatch {
  ShareSourceWatch({
    required Stream<String> Function() captureErrors,
    required Future<void> Function(ShareRequest request) stop,
  })  : _captureErrors = captureErrors,
        _stop = stop;

  final Stream<String> Function() _captureErrors;
  final Future<void> Function(ShareRequest request) _stop;
  final _lost = StreamController<String>.broadcast();
  StreamSubscription<String>? _subscription;
  ShareRequest? _running;

  /// The source id of a share that ended because its source went away.
  Stream<String> get lost => _lost.stream;

  /// Listens only while a share runs, so a call without one never touches the plugin.
  void running(ShareRequest? request) {
    _running = request;
    if (request == null) {
      unawaited(_subscription?.cancel());
      _subscription = null;
    } else {
      _subscription ??= _captureErrors().listen(_onError);
    }
  }

  Future<void> _onError(String sourceId) async {
    final request = _running;
    final shared = request?.sourceId;
    if (request == null || shared == null) return;
    if (sourceId.isNotEmpty && sourceId != shared) return;
    running(null);
    await _stop(request);
    if (!_lost.isClosed) _lost.add(shared);
  }

  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_lost.close());
  }
}
