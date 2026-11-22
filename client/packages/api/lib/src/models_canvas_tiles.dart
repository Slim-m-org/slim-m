// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Module tiles on a canvas: what a member may place, and a tile's shared frame.
library;

import 'models_dock_activity.dart';

/// The canvas object kind a module tile is stored as.
const canvasModuleTileKind = 'module';

/// A `canvas-tile` extension point the caller may place, from `GET /modules/canvas-tiles`.
class CanvasTileOffer {
  const CanvasTileOffer({
    required this.moduleId,
    required this.tile,
    this.description,
    this.module,
  });

  final String moduleId;

  /// The point's name: what a placed object's `props.tile` carries and the place menu shows.
  final String tile;
  final String? description;
  final ModuleInfo? module;

  factory CanvasTileOffer.fromJson(Map<String, dynamic> json) =>
      CanvasTileOffer(
        moduleId: json['module_id'] as String,
        tile: json['tile'] as String,
        description: json['description'] as String?,
        module: ModuleInfo.fromJson(json['module']),
      );

  /// The `props` of a `module` canvas object that places this tile.
  Map<String, dynamic> get props => {'module_id': moduleId, 'tile': tile};
}

/// A module tile's last stored frame, which every viewer of the canvas draws.
class CanvasTileScene {
  const CanvasTileScene({
    required this.objectId,
    required this.output,
    required this.ranAt,
    this.ranBy,
  });

  final String objectId;
  final String output;
  final int ranAt;
  final String? ranBy;

  factory CanvasTileScene.fromJson(Map<String, dynamic> json) =>
      CanvasTileScene(
        objectId: json['object_id'] as String,
        output: json['output'] as String,
        ranAt: (json['ran_at'] as num?)?.toInt() ?? 0,
        ranBy: json['ran_by'] as String?,
      );
}
