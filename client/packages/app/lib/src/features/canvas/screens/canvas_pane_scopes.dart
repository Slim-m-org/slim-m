// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scopes every canvas pane descendant reads: the real-window flag, object locks, group actions and module tiles.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;

import 'canvas_group_actions.dart';
import 'canvas_module_tile_scope.dart';
import 'canvas_object_locks.dart';
import 'canvas_real_window.dart';

class CanvasPaneScopes extends StatelessWidget {
  const CanvasPaneScopes({
    super.key,
    required this.realWindow,
    required this.locks,
    required this.groupActions,
    required this.channelId,
    required this.onPlaceModuleTile,
    required this.child,
  });

  final bool realWindow;
  final CanvasObjectLocks locks;
  final CanvasGroupActions groupActions;
  final String channelId;

  /// Null while placing would be refused.
  final ValueChanged<api.CanvasTileOffer>? onPlaceModuleTile;
  final Widget child;

  @override
  Widget build(BuildContext context) => CanvasRealWindowScope(
    active: realWindow,
    child: CanvasObjectLocksScope(
      locks: locks,
      child: CanvasGroupActionsScope(
        actions: groupActions,
        child: CanvasModuleTileScope(
          channelId: channelId,
          onPlace: onPlaceModuleTile,
          child: child,
        ),
      ),
    ),
  );
}
