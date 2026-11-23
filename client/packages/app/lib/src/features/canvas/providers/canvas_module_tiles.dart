// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Module tiles on a canvas: which ones the viewer may place, and each placed tile's shared frame.
///
/// A tile's frame lives on the server and reaches every viewer as
/// `canvas.tile.scene_changed`; this holds the latest one per object, fetched
/// once when a tile first shows and launched when it has none yet.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// Which module and which of its tiles a `module` canvas object names.
class ModuleTileRef {
  const ModuleTileRef({required this.moduleId, required this.tile});

  final String moduleId;
  final String tile;

  /// What every module tile's document key starts with; another tile kind takes a prefix of its own.
  static const keyPrefix = 'module:';

  /// The opaque key the canvas document carries for the tile; a module id is a slug, so it holds no `/`.
  String get key => '$keyPrefix$moduleId/$tile';

  /// The tile [key] names, or null for a key that is not a module tile's.
  static ModuleTileRef? fromKey(String key) {
    if (!key.startsWith(keyPrefix)) return null;
    final rest = key.substring(keyPrefix.length);
    final cut = rest.indexOf('/');
    if (cut <= 0 || cut == rest.length - 1) return null;
    return ModuleTileRef(
      moduleId: rest.substring(0, cut),
      tile: rest.substring(cut + 1),
    );
  }

  /// A wire object's `props`, or null when either field is missing or not a string.
  static ModuleTileRef? fromProps(Map<String, dynamic> props) {
    final moduleId = props['module_id'];
    final tile = props['tile'];
    if (moduleId is! String || tile is! String) return null;
    if (moduleId.isEmpty || moduleId.contains('/') || tile.isEmpty) return null;
    return ModuleTileRef(moduleId: moduleId, tile: tile);
  }
}

/// The tiles this viewer may place; empty on a server without module tiles.
final canvasTileOffersProvider =
    FutureProvider.autoDispose<List<api.CanvasTileOffer>>(
      (ref) => ref.watch(apiProvider).listCanvasTiles(),
    );

/// One tile's frame as this viewer holds it.
class CanvasTileFrame {
  const CanvasTileFrame.loading() : output = null, error = null;
  const CanvasTileFrame.shown(String this.output) : error = null;
  const CanvasTileFrame.failed(String this.error) : output = null;

  /// The module's last stored output, normally a scene; null until one arrives.
  final String? output;

  /// Why the tile cannot show its frame, such as its module being uninstalled.
  final String? error;
}

/// Every tile frame on one channel's canvas, keyed by object id.
class CanvasTileFrames
    extends AutoDisposeFamilyNotifier<Map<String, CanvasTileFrame>, String> {
  @override
  Map<String, CanvasTileFrame> build(String channelId) {
    _disposed = false;
    final sub = ref.watch(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      sub.cancel();
    });
    // A frame sent while the socket was down never arrives; read every held one again.
    ref.listen(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        for (final id in state.keys.toList()) {
          unawaited(_refresh(id));
        }
      }
    });
    return const {};
  }

  /// The count of live frames per object, so a read that left before one can tell.
  final _liveFrames = <String, int>{};

  /// A fetch can answer after the last tile on screen went away.
  bool _disposed = false;

  String get channelId => arg;

  void _onEvent(api.ServerEvent event) {
    if (event case api.CanvasTileSceneChanged(
      :final channelId,
      :final objectId,
      :final output,
    ) when channelId == this.channelId) {
      _liveFrames[objectId] = (_liveFrames[objectId] ?? 0) + 1;
      _set(objectId, CanvasTileFrame.shown(output));
    }
  }

  void _set(String objectId, CanvasTileFrame frame) {
    if (_disposed) return;
    state = {...state, objectId: frame};
  }

  api.SlimmApi get _client => ref.read(apiProvider);

  /// Fetches [objectId]'s frame the first time a tile asks, launching it when it has none; [retry] asks again after a failure.
  Future<void> ensure(String objectId, {bool retry = false}) async {
    final current = state[objectId];
    if (current != null && !(retry && current.error != null)) return;
    _set(objectId, const CanvasTileFrame.loading());
    final liveBefore = _liveFrames[objectId];
    try {
      final stored = await _client.canvasTileScene(
        channelId: channelId,
        objectId: objectId,
      );
      if (_liveFrames[objectId] != liveBefore) return;
      if (stored != null) {
        _set(objectId, CanvasTileFrame.shown(stored.output));
        return;
      }
      final launched = await press(objectId, '');
      if (!launched.ok) {
        _set(
          objectId,
          CanvasTileFrame.failed(launched.error ?? 'This tile did not start.'),
        );
      }
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'show a module tile', e, stack);
      _set(
        objectId,
        CanvasTileFrame.failed(describeApiFailure('show this tile', e)),
      );
    }
  }

  /// Reads [objectId]'s stored frame again, keeping what is shown until it lands or when it fails.
  Future<void> _refresh(String objectId) async {
    final liveBefore = _liveFrames[objectId];
    try {
      final stored = await _client.canvasTileScene(
        channelId: channelId,
        objectId: objectId,
      );
      if (stored == null || _liveFrames[objectId] != liveBefore) return;
      _set(objectId, CanvasTileFrame.shown(stored.output));
    } on api.ApiException catch (e, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not refresh a module tile after reconnecting',
        e,
        stack,
      );
    }
  }

  /// Presses [objectId] with an action frame, or launches it with an empty [input]; a stored answer is shown at once.
  Future<api.RunModuleCommandResult> press(
    String objectId,
    String input,
  ) async {
    final result = await _client.pressCanvasTile(
      channelId: channelId,
      objectId: objectId,
      input: input,
    );
    final output = result.output;
    if (result.ok && output != null && state[objectId]?.output == null) {
      _set(objectId, CanvasTileFrame.shown(output));
    }
    return result;
  }
}

final canvasTileFramesProvider = NotifierProvider.autoDispose
    .family<CanvasTileFrames, Map<String, CanvasTileFrame>, String>(
      CanvasTileFrames.new,
    );
