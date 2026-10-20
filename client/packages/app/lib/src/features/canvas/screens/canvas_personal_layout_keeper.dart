// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps one channel's personal canvas layout on this device and puts it back
/// when the canvas is opened again. Decision 0082.
///
/// The layout is local convenience state: it goes to the drift store and never
/// to the server.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_data/data.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// How long a pan or drag settles before the layout is written.
const Duration personalLayoutSaveDelay = Duration(milliseconds: 400);

/// The store once it opens, or null after logging why it could not.
Future<CanvasLayoutStore?> openLayoutStore(Future<CanvasLayoutStore> opening) =>
    opening.then<CanvasLayoutStore?>((store) => store).catchError((
      Object error,
      StackTrace stack,
    ) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not open the layout store; the personal layout will not save',
        error,
        stack,
      );
      return null;
    });

class CanvasPersonalLayoutKeeper {
  CanvasPersonalLayoutKeeper({
    required this.channelId,
    required this.mode,
    required this.store,
    this.saveDelay = personalLayoutSaveDelay,
  }) {
    _kept = mode.layout.encode();
    mode.addListener(_onLayoutMaybeChanged);
    mode.tiles.addListener(_onLayoutMaybeChanged);
    mode.document.addListener(_onCameraMaybeMoved);
  }

  final String channelId;
  final CanvasViewMode mode;

  /// Resolved once, up front: the provider that made it is gone by [dispose].
  final Future<CanvasLayoutStore?> store;
  final Duration saveDelay;

  String _kept = '';
  Camera? _camera;
  Timer? _timer;
  bool _restoring = true;
  bool _touched = false;
  bool _disposed = false;

  /// Puts back what was kept; anything the viewer did while it loaded wins and is saved.
  Future<void> restore() async {
    try {
      final raw = await (await store)?.load(channelId);
      if (_disposed || raw == null) return;
      final kept = CanvasPersonalLayout.decode(raw);
      if (kept == null) return;
      _touched ? mode.restoreBeneath(kept) : mode.restore(kept);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not read the personal canvas layout; starting from the shared view',
        error,
        stack,
      );
    } finally {
      _restoring = false;
      if (_touched && !_disposed) {
        _timer?.cancel();
        _timer = Timer(saveDelay, _write);
      } else {
        _kept = mode.layout.encode();
      }
    }
  }

  void _onCameraMaybeMoved() {
    if (!mode.personal || mode.document.camera == _camera) return;
    _camera = mode.document.camera;
    _onLayoutMaybeChanged();
  }

  void _onLayoutMaybeChanged() {
    if (_disposed) return;
    if (_restoring) {
      _touched = _touched || mode.layout.encode() != _kept;
      return;
    }
    _timer?.cancel();
    _timer = Timer(saveDelay, _write);
  }

  void _write() {
    _timer = null;
    final layout = mode.layout;
    final encoded = layout.encode();
    if (encoded == _kept) return;
    _kept = encoded;
    unawaited(_persist(layout, encoded));
  }

  Future<void> _persist(CanvasPersonalLayout layout, String encoded) async {
    try {
      final target = await store;
      if (layout.isEmpty) {
        await target?.delete(channelId);
      } else {
        await target?.save(
          channelId,
          encoded,
          now: DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not save the personal canvas layout; kept for this session only',
        error,
        stack,
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_timer != null && !_restoring) _write();
    _timer?.cancel();
    _disposed = true;
    mode.removeListener(_onLayoutMaybeChanged);
    mode.tiles.removeListener(_onLayoutMaybeChanged);
    mode.document.removeListener(_onCameraMaybeMoved);
  }
}
