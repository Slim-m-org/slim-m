// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scene contract: how slim turns a module's opaque output string into
/// something it can paint, without slim or the module knowing anything about
/// each other's internals.
///
/// A module returns a plain string (module ABI v1 has no content type). When
/// that string parses as a JSON object tagged `"$slim": "scene/1"`, slim reads
/// it as a scene and paints it (see `module_scene_painter.dart`) instead of
/// showing the raw text; anything else stays plain text exactly as before. So
/// this is a client-side reading of an ordinary string, not a wire change: a
/// module opts in simply by choosing to emit one.
///
/// Colours are named, not baked: an op may name a theme token (`accent`,
/// `surface`, `sunken`, `muted`, `text`, `border`, `danger`) and the painter
/// resolves it against the viewer's theme, so a module's drawing looks native
/// in light and dark alike without the module knowing which is in force. A
/// literal `#rrggbb` still passes through untouched.
library;

import 'dart:ui' show Rect;

export 'module_scene_parse.dart' show parseModuleScene;
export 'module_scene_ops.dart';
export 'module_scene_types.dart';
export 'module_scene_sweep.dart' show SceneSweep;

import 'module_scene_ops.dart';

/// A whole scene: a logical canvas, the ops to draw on it, the opaque [state]
/// the module wants handed back on the next call, the [controls] to offer, a
/// one-line [status] caption, and whether the scene can still change ([live]).
class ModuleScene {
  const ModuleScene({
    required this.width,
    required this.height,
    required this.ops,
    this.background,
    this.state,
    this.controls = const [],
    this.status,
    this.live = false,
    this.isPrivate = false,
    this.crop,
    this.source,
  });

  /// The output string this scene was read from, when it was read from one.
  ///
  /// `state` is optional, so it cannot tell two frames apart on its own: a
  /// module with nothing to remember sends new ops under the same, absent, state.
  final String? source;

  /// Whether [other] is the frame this one already is, which is what a rebuild
  /// from above that changed nothing looks like.
  bool isSameFrame(ModuleScene other) =>
      state == other.state && source == other.source;

  /// Whether the module asked for this frame to be shown to this viewer only (decision 0099): the
  /// host neither stores nor broadcasts it, so it is held on screen until the viewer closes it.
  final bool isPrivate;

  /// The part of the canvas worth showing, in scene units, or null for all of
  /// it. See `module_scene_bounds.dart`.
  final Rect? crop;

  ModuleScene withCrop(Rect? crop) => ModuleScene(
    width: width,
    height: height,
    ops: ops,
    background: background,
    state: state,
    controls: controls,
    status: status,
    live: live,
    isPrivate: isPrivate,
    crop: crop,
    source: source,
  );

  /// Whether any op answers a right click or a long press.
  bool get hasSecondary => ops.any(
    (op) => switch (op) {
      CellsOp() => op.alt != null,
      RectOp() => op.alt != null,
      _ => false,
    },
  );

  double get viewLeft => crop?.left ?? 0;
  double get viewTop => crop?.top ?? 0;
  double get viewWidth => crop?.width ?? width;
  double get viewHeight => crop?.height ?? height;

  /// The widest ratio between a scene's long and short axis, clamped at parse.
  ///
  /// Chosen from phone width: a 4:1 board on a 390px card is still 98px tall,
  /// enough to see and aim at, where the 1000:1 a module could declare was a
  /// 3px sliver. Like [CellsOp.maxPerAxis] it is a ceiling set by what a
  /// person can use, not by whatever else happens to bound the scene.
  static const maxAspect = 4.0;

  /// How many control buttons a scene may offer; the shipped modules use at
  /// most eight, and each one is a button in a row under the board.
  static const maxControls = 16;

  final double width;
  final double height;
  final List<SceneOp> ops;
  final String? background;
  final String? state;
  final List<String> controls;
  final String? status;
  final bool live;
}
