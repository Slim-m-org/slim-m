// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fixed sizes and durations `canvas_presence_tile.dart` builds its
/// gesture and reveal behaviour around - split out once that file crossed
/// the review budget, since these carry no logic of their own to keep them
/// near.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// The world-space box a resize may not shrink below or grow past - small
/// enough that the name badge and controls still fit, large enough that a
/// single tile can never swallow a typical viewport.
const canvasPresenceTileMinSize = Size(72, 54);
const canvasPresenceTileMaxSize = Size(720, 540);

/// How long a touch reveal stays up with nothing else keeping it there - a
/// mouse instead relies on [MouseRegion.onExit] firing the moment the
/// pointer actually leaves, so this only ever governs touch.
const canvasPresenceTileTouchRevealDuration = Duration(seconds: 3);

/// The tile-edge gap [CanvasPresenceManipulableTile] leaves around its control row.
const canvasPresenceTileControlsInset = 2.0;

/// How many of a tile's hover buttons fit a [screen] box at [touch] density; the row never overflows the tile nor meets the resize grip.
int canvasPresenceTileControlCapacity(Size screen, {required bool touch}) {
  final slot = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
  final grip = touch ? AppSizes.rowTouch : AppSizes.controlSm;
  if (screen.height < slot + grip + canvasPresenceTileControlsInset) return 0;
  final room = screen.width - 2 * canvasPresenceTileControlsInset;
  return (room / slot).floor().clamp(0, 3);
}
