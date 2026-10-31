// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';

import 'module_scene.dart';
import 'module_scene_painter.dart';
import 'module_scene_queue.dart';

/// The last few scene states a view produced itself.
///
/// A scene that belongs to a message is shared: every action stores the new
/// output on the message and broadcasts it, so a view's own step comes
/// straight back as a new initial scene. Without this it read as somebody
/// starting a new run and stopped the very timer that had just produced it.
class SceneOwnStates {
  static const _memory = 8;

  final _states = <String>{};

  bool contains(String? state) => state != null && _states.contains(state);

  void remember(String? state) {
    if (state == null) return;
    _states.add(state);
    if (_states.length > _memory) _states.remove(_states.first);
  }
}

/// Turns pointer input on a scene into queued actions.
class SceneGestures {
  SceneGestures({
    required this.scene,
    required this.queue,
    required this.enqueue,
  });

  /// The current scene, read at each gesture rather than captured once.
  final ModuleScene Function() scene;
  final SceneActionQueue queue;
  final void Function(String action) enqueue;

  /// Where the current gesture began, remembered because `onPanStart` reports
  /// the point at which the drag was recognised, a cell or two past the point
  /// the finger came down on.
  Offset? _downAt;

  /// The raw pointer-down, not `onTapDown`: the tap recogniser is rejected
  /// before its own deadline when a drag is quick, so `onTapDown` never fires
  /// for exactly the gestures this needs to know the origin of.
  void pointerDown(PointerDownEvent event) {
    _downAt = event.localPosition;
    queue.startDrag();
  }

  void tapUp(TapUpDetails details, Size size) {
    final action = sceneTapAction(scene(), details.localPosition, size);
    if (action != null) enqueue(action);
  }

  void secondary(Offset at, Size size) {
    final action = sceneTapAction(scene(), at, size, secondary: true);
    if (action != null) enqueue(action);
  }

  /// Paints the cell the finger landed on, then the one the drag was
  /// recognised in; the dedupe set makes a shared cell a single paint.
  void panStart(DragStartDetails details, Size size) {
    final down = _downAt;
    if (down != null) _paintCell(down, size);
    _paintCell(details.localPosition, size);
  }

  void panUpdate(DragUpdateDetails details, Size size) =>
      _paintCell(details.localPosition, size);

  /// Sends the cell under [local] once per drag; bare-action ops (a button
  /// drawn into the scene) are ignored, since a drag across one is no press.
  void _paintCell(Offset local, Size size) {
    final action = sceneTapAction(scene(), local, size);
    if (action == null || !action.contains(':')) return;
    if (!queue.markPainted(action)) return;
    enqueue(action);
  }
}
